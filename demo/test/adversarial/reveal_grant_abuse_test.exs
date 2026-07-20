defmodule Demo.Adversarial.RevealGrantAbuseTest do
  @moduledoc """
  T4.6 — ADVERSARIAL suite, category 2: REVEAL-GRANT ABUSE.

  Consolidated Phase-4 attack surface (plan §6.3 "Reveal-grant abuse"), driven against
  the REAL T1.6 reveal-grant model (`Samen.Reveal.Grants`) on `Demo.Repo`, keyed on a
  REAL demo subject (a `Demo.Crm.Contact` id):

    (1) SELF-APPROVAL — blocked at the POLICY layer (`{:error, :self_approval}`, no
        grant row) AND at the DB layer (`rvg_distinct_party` CHECK rejects a direct
        insert with `granted_by == requestor_id`).
    (2) EXPIRED grant — deny-on-read: `active?` is FALSE once `now() > expires_at` even
        with the row still present and un-revoked (no cleanup dependency).
    (3) RENEW-IN-PLACE — `attempt_extend` always fails; no path mutates `expires_at`;
        re-access requires a FRESH request + approval (a new grant row).
    (4) GRANT-ROW TAMPER — a reveal event lands on the hash-chained tenant-readable
        audit; editing that chained row (out-of-band SQL) is DETECTED by
        `AuditChain.verify_chain` (`:hash_mismatch`).
    (5) REQUESTOR-APPROVER COLLUSION via a SECOND ACCOUNT — the DOCUMENTED RESIDUE: an
        operator files under a burner requestor id they control, then approves as a
        DISTINCT account. Allowed by the mechanics (dual-control's honest edge), BUT
        the two colluding identities are VISIBLE in the tenant-readable audit — this
        test ASSERTS that visibility (both ids on the grant row + both events in the
        audit trail + the reveal event on the tenant-readable chain).

  POSITIVE CONTROL on every red path: the legitimate request → distinct-party approve →
  live-window reveal SUCCEEDS, so each denial is non-vacuous.

  Tag: `@moduletag :adversarial`.
  """
  use Demo.DataCase, async: false

  @moduletag :adversarial

  import Ecto.Query

  alias Samen.Reveal.Grants
  alias Samen.Reveal.{RevealGrant, RevealAudit}
  alias Samen.AuditChain

  @repo Demo.Repo

  # A real demo subject (a Contact). Its id is the reveal subject_id.
  defp mk_subject do
    {:ok, org} =
      Demo.Identity.Org
      |> Ash.Changeset.for_create(:create, %{name: "AbuseOrg-#{System.unique_integer([:positive])}"})
      |> Ash.create(authorize?: false)

    {:ok, contact} =
      Demo.Crm.Contact
      |> Ash.Changeset.for_create(:create, %{
        display_name: "Subject",
        org_id: org.id,
        full_name: %{first: "Sub", last: "Ject"},
        emails: ["subject@abuse.test"]
      })
      |> Ash.create(authorize?: false)

    %{org_id: org.id, subject_id: contact.id}
  end

  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  # ==========================================================================
  # POSITIVE CONTROL — the legitimate reveal path succeeds (non-vacuity anchor)
  # ==========================================================================

  test "POSITIVE CONTROL: request → distinct-party approve → live-window reveal SUCCEEDS" do
    %{subject_id: s} = mk_subject()
    requestor = actor()
    approver = actor()

    {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "legit ticket"})
    {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 15})

    assert grant.requestor_id == requestor
    assert grant.granted_by == approver
    # The REQUESTOR holds the capability inside the window.
    assert Grants.active?(requestor, s)
  end

  # ==========================================================================
  # (1) SELF-APPROVAL — blocked at POLICY and at the DB CHECK
  # ==========================================================================

  describe "(1) self-approval" do
    test "RED: self-approval blocked at the POLICY layer (no grant row)" do
      %{subject_id: s} = mk_subject()
      me = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: me, reason: "sketchy"})

      assert {:error, :self_approval} = Grants.approve(req, %{granted_by: me})

      grants = @repo.all(from(g in RevealGrant, where: g.subject_id == ^s))
      assert grants == []
    end

    test "RED: a DIRECT insert with granted_by == requestor_id raises the rvg_distinct_party DB CHECK" do
      %{subject_id: s} = mk_subject()
      same = "same-party-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      expires = DateTime.add(now, 900, :second)

      # Raw SQL — no application code, no changeset mapping. The DB CHECK is the only
      # thing that can reject this, proving self-approval is impossible at storage.
      assert_raise Postgrex.Error, ~r/rvg_distinct_party/, fn ->
        @repo.query!(
          """
          INSERT INTO rvg_reveal_grant
            (rvg_id, rvg_request_id, rvg_subject_id, rvg_requestor_id, rvg_granted_by,
             rvg_reason, rvg_expires_at, rvg_inserted_at, rvg_updated_at)
          VALUES
            (gen_random_uuid(), gen_random_uuid(), $1, $2, $2, 'raw', $3, $4, $4)
          """,
          [s, same, expires, now]
        )
      end
    end

    test "POSITIVE CONTROL: a DISTINCT-party direct insert SUCCEEDS (the CHECK only blocks self)" do
      %{subject_id: s} = mk_subject()
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      expires = DateTime.add(now, 900, :second)

      assert %Postgrex.Result{num_rows: 1} =
               @repo.query!(
                 """
                 INSERT INTO rvg_reveal_grant
                   (rvg_id, rvg_request_id, rvg_subject_id, rvg_requestor_id, rvg_granted_by,
                    rvg_reason, rvg_expires_at, rvg_inserted_at, rvg_updated_at)
                 VALUES
                   (gen_random_uuid(), gen_random_uuid(), $1, $2, $3, 'raw', $4, $5, $5)
                 """,
                 [s, "requestor-#{System.unique_integer([:positive])}",
                  "approver-#{System.unique_integer([:positive])}", expires, now]
               )
    end
  end

  # ==========================================================================
  # (2) EXPIRED grant — deny-on-read even with a stale, un-revoked row
  # ==========================================================================

  describe "(2) expired grant" do
    test "RED: active? is FALSE once now() > expires_at with the row present and un-revoked" do
      %{subject_id: s} = mk_subject()
      requestor = actor()
      approver = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 1})

      # POSITIVE CONTROL: inside the window, active.
      assert Grants.active?(requestor, s)

      # The row still exists and is NOT revoked (auto-revoke job did not run).
      reloaded = @repo.get(RevealGrant, grant.id)
      assert reloaded.revoked_at == nil

      # After expiry: deny-on-read fires with only the clock moved.
      future = DateTime.add(grant.expires_at, 60, :second)
      refute Grants.active?(requestor, s, now: future)
    end
  end

  # ==========================================================================
  # (3) RENEW-IN-PLACE — no path mutates expires_at; re-access = fresh grant
  # ==========================================================================

  describe "(3) renew-in-place" do
    test "RED: attempt_extend fails; expires_at is unchanged in the DB" do
      %{subject_id: s} = mk_subject()
      requestor = actor()
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
      {:ok, grant} = Grants.approve(req, %{granted_by: actor(), window_minutes: 1})

      new_expiry = DateTime.add(grant.expires_at, 3600, :second)
      assert {:error, :no_renew_in_place} = Grants.attempt_extend(grant.id, new_expiry)
      assert @repo.get(RevealGrant, grant.id).expires_at == grant.expires_at
    end

    test "POSITIVE CONTROL: re-access after revoke requires a FRESH request + approval (new row)" do
      %{subject_id: s} = mk_subject()
      requestor = actor()
      approver = actor()
      {:ok, req1} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r1"})
      {:ok, grant1} = Grants.approve(req1, %{granted_by: approver, window_minutes: 60})
      {:ok, _} = Grants.revoke(grant1.id)
      refute Grants.active?(requestor, s)

      {:ok, req2} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r2"})
      {:ok, grant2} = Grants.approve(req2, %{granted_by: approver, window_minutes: 60})
      assert grant2.id != grant1.id
      assert Grants.active?(requestor, s)
    end
  end

  # ==========================================================================
  # (4) GRANT-ROW TAMPER — a reveal event on the hash chain; edit is detected
  # ==========================================================================

  describe "(4) grant-row / audit-chain tamper" do
    test "RED: editing a chained reveal audit row is detected by verify_chain (:hash_mismatch)" do
      %{org_id: org} = mk_subject()

      # Land two reveal-lifecycle events on the org's tenant-readable hash chain.
      {:ok, e0} =
        AuditChain.append(
          %{
            org_id: org,
            event_type: "reveal",
            subject_id: "subj-#{System.unique_integer([:positive])}",
            actor_id: actor(),
            detail: "event=granted"
          },
          repo: @repo
        )

      {:ok, _e1} =
        AuditChain.append(
          %{
            org_id: org,
            event_type: "reveal",
            subject_id: "subj-#{System.unique_integer([:positive])}",
            actor_id: actor(),
            detail: "event=revoked"
          },
          repo: @repo
        )

      # POSITIVE CONTROL: the untampered chain verifies.
      assert {:ok, %{entries: 2}} = AuditChain.verify_chain(org, repo: @repo)

      # An attacker with DB access disables the append-only trigger and rewrites the
      # detail of the granted event to hide it.
      @repo.query!("ALTER TABLE aud_chain DISABLE TRIGGER aud_chain_append_only_tg")
      @repo.query!("UPDATE aud_chain SET ach_detail = 'event=DENIED cover-up' WHERE ach_id = $1", [
        Ecto.UUID.dump!(e0.id)
      ])
      @repo.query!("ALTER TABLE aud_chain ENABLE TRIGGER aud_chain_append_only_tg")

      # The stored hash no longer matches the recomputed hash over the edited payload.
      assert {:error, {:hash_mismatch, 0}} = AuditChain.verify_chain(org, repo: @repo)
    end

    test "RED: the append-only trigger blocks an ordinary UPDATE/DELETE on a chained row" do
      %{org_id: org} = mk_subject()

      {:ok, e0} =
        AuditChain.append(
          %{org_id: org, event_type: "reveal", subject_id: "s", actor_id: "op", detail: "event=granted"},
          repo: @repo
        )

      assert_raise Postgrex.Error, ~r/append-only/i, fn ->
        @repo.query!("UPDATE aud_chain SET ach_detail = 'x' WHERE ach_id = $1", [
          Ecto.UUID.dump!(e0.id)
        ])
      end

      assert_raise Postgrex.Error, ~r/append-only/i, fn ->
        @repo.query!("DELETE FROM aud_chain WHERE ach_id = $1", [Ecto.UUID.dump!(e0.id)])
      end
    end
  end

  # ==========================================================================
  # (5) REQUESTOR-APPROVER COLLUSION via a second account — RESIDUE, but VISIBLE
  # ==========================================================================

  describe "(5) requestor-approver collusion (documented residue, audit-visible)" do
    test "collusion via a second account IS allowed by the mechanics — and BOTH identities are VISIBLE in the audit" do
      %{subject_id: s} = mk_subject()

      # A malicious operator controls TWO accounts: a burner requestor and their own
      # id. They file under the burner and approve as themselves (a DISTINCT party).
      burner_requestor = "burner-#{System.unique_integer([:positive])}"
      colluding_approver = "operator-#{System.unique_integer([:positive])}"

      {:ok, req} =
        Grants.request(%{subject_id: s, requestor_id: burner_requestor, reason: "coordinated reveal"})

      # The mechanics ALLOW this — distinct-party approval passes (the honest residue
      # the doc names: dual-control cannot stop two coordinating identities).
      {:ok, grant} = Grants.approve(req, %{granted_by: colluding_approver, window_minutes: 60})

      # The capability binds to the REQUESTOR (burner), not the approver — so the
      # approver alone cannot reveal (throwaway-requestor self-serve is closed).
      assert Grants.active?(burner_requestor, s)
      refute Grants.active?(colluding_approver, s)

      # ---- THE ASSERTED VISIBILITY (the residue is not silent) ----

      # (a) the grant row itself records BOTH colluding identities.
      assert grant.requestor_id == burner_requestor
      assert grant.granted_by == colluding_approver

      # (b) the tenant-readable reveal audit trail records BOTH events with BOTH ids.
      audit = Grants.audit_for(s, repo: @repo)
      events = Map.new(audit, &{&1.event, &1})

      assert events["requested"].actor_id == burner_requestor
      assert events["granted"].actor_id == colluding_approver

      # (c) both distinct identities are recoverable from the audit for forensics.
      actor_ids = audit |> Enum.map(& &1.actor_id) |> Enum.uniq() |> Enum.sort()
      assert burner_requestor in actor_ids
      assert colluding_approver in actor_ids
      assert length(actor_ids) == 2, "the collusion pairs TWO distinct ids — both must be visible"
    end

    test "POSITIVE CONTROL: a lone operator CANNOT self-serve (approve then reveal as approver)" do
      %{subject_id: s} = mk_subject()
      me = actor()

      # File under my own id, try to approve myself → self-approval blocked, no grant.
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: me, reason: "solo attempt"})
      assert {:error, :self_approval} = Grants.approve(req, %{granted_by: me})

      # No capability — the single-actor self-serve path is dead.
      refute Grants.active?(me, s)

      # And a denied event is written (the attempt is auditable).
      assert Enum.any?(Grants.audit_for(s, repo: @repo), &(&1.event == "denied"))
    end
  end

  # A tiny guard so RevealAudit is referenced (compile-time alias hygiene).
  test "the reveal audit schema is the tenant-readable trail" do
    # Force the module to load before probing its exports: `function_exported?/3`
    # returns false for a not-yet-loaded module, so under a concurrent/async run this
    # assertion was order-dependent. Loading first makes it deterministic without
    # weakening what it proves (RevealAudit is a schema exporting __schema__/1).
    assert {:module, RevealAudit} = Code.ensure_loaded(RevealAudit)
    assert function_exported?(RevealAudit, :__schema__, 1)
  end
end
