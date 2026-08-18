defmodule Samen.VersionedChangeLogTest do
  @moduledoc """
  E7 audit-on-write — the general `versioned` opt-in (ADR-040 §6, T119; the pieces T38
  phased out per §6.7). Proven on two kernel pilots (`SamenCore.Support.Versioning`):

    * `Contact` — `versioned: true` (**`:changes_only`**), folds `Core.Person`.
    * `Snapshot` — `versioned: :snapshot` + `archivable`, folds `Core.Person` (the CMS
      content shape, §6.5).

  Done-criteria (T119 handoff 1/2/6), every red-path paired with a positive control:

    * **c1 change-log**: a `versioned` create/update/archive writes an attributable
      `<Resource>.Version` row (actor via org mirror, diff, timestamp); a non-opted
      resource (`Widget` — archivable, NOT versioned) writes none (CONTROL).
    * **c2 INV-1 token-only diffs** (§6.3(1)): a vault-attribute diff stores the `vt_*`
      token, never the sentinel plaintext — for BOTH `:changes_only` AND, decisively,
      `:snapshot` (the full-row reconstruction, the mode most able to leak). A plain
      (non-PII) attribute stores its cleartext (proving the token is the vault type's
      doing, not blanket redaction). Anti-tautology: the leak scan is refutable.
    * **c2 store_action_inputs? off** (§6.3(2)): FALSE on every versioned resource and
      the `version_action_inputs` column is not even generated.
    * **c2 masked-render**: a vault-attribute diff value renders through the masking
      path as `••••`, never the raw `vt_*` token (§6.3(4)).
    * **c6 four-tiers-disjoint** (§7.4): a versioned + impersonated write produces BOTH a
      Version row (E7) AND exactly one §6.6 `impersonation_write` governance `aud_event` —
      never a second `aud_event` for the version-row write itself (the
      `Samen.Audit.ImpersonationWrite` version-resource guard).

  The sabotage (`scripts/sabotages/35-e7-versioned-inv1-tiers-drop.patch`) neutralizes
  the vault type's dump face so a diff would carry plaintext — the INV-1 RED tests then
  fail — AND drops the version-resource guard so the tiers-disjoint RED sees two rows.
  """
  use ExUnit.Case, async: false

  import Samen.MaskingCase, only: [assert_leak_detected!: 2]

  alias Samen.OperatorPlane.Actor
  alias SamenCore.Support.Versioning.{Contact, Snapshot}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp tenant_scope(org) do
    %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp person_attrs(org, label, first, last, email) do
    Map.merge(
      %{org_id: org, label: label},
      Samen.Factory.person(first, last, email: email)
    )
  end

  # Raw-SQL readers over the version tables (the physical truth — no masking, no Ash
  # loading in the way; this is what actually landed at rest).
  defp version_count(table, org) do
    %{rows: [[n]]} =
      @repo.query!(
        "SELECT count(*) FROM #{table} WHERE #{prefix(table)}_org_id = $1",
        [Ecto.UUID.dump!(org)]
      )

    n
  end

  defp version_changes(table, org) do
    p = prefix(table)

    %{rows: rows} =
      @repo.query!(
        "SELECT #{p}_changes, #{p}_version_action_type, #{p}_org_id FROM #{table} " <>
          "WHERE #{p}_org_id = $1 ORDER BY #{p}_version_inserted_at",
        [Ecto.UUID.dump!(org)]
      )

    Enum.map(rows, fn [changes, action, org_bin] ->
      %{changes: changes, action: action, org_id: Ecto.UUID.load!(org_bin)}
    end)
  end

  defp prefix("svc_contact_versions"), do: "vcv"
  defp prefix("svs_snapshot_versions"), do: "vsv"

  # ── c1 · change-log basics + control ────────────────────────────────────────

  test "a versioned CREATE then UPDATE each write an attributable Version row; a non-opted resource writes none",
       %{org: org, scope: scope} do
    assert Samen.Info.versioned?(Contact)
    assert Samen.Info.versioned_mode(Contact) == :changes_only

    # CONTROL: Widget is archivable but NOT versioned — it has no Version resource and
    # writes no version rows. A blanket-adoption regression would break this.
    refute Samen.Info.versioned?(SamenCore.Support.Archivable.Widget)
    refute function_exported?(SamenCore.Support.Archivable.Widget, :resource_version?, 0)

    contact = Samen.Factory.create!(Contact, person_attrs(org, "v1", "Ada", "Lovelace", "ada@x.invalid"), scope)
    assert version_count("svc_contact_versions", org) == 1

    contact
    |> Ash.Changeset.for_update(:update, %{label: "v2"}, scope: scope)
    |> Ash.update!()

    rows = version_changes("svc_contact_versions", org)
    assert length(rows) == 2
    assert Enum.map(rows, & &1.action) == ["create", "update"]
    # §6.2: org_id is mirrored onto every version row (a real NOT-NULL column).
    assert Enum.all?(rows, &(&1.org_id == org))
  end

  # ── c2 · INV-1 token-only diffs (:changes_only) ─────────────────────────────

  test "INV-1 (§6.3(1), :changes_only): a vault-attribute diff stores the vt_ token, never plaintext; a plain field stays cleartext",
       %{org: org, scope: scope} do
    _ = Samen.Factory.create!(Contact, person_attrs(org, "hello", "Ada", "Lovelace", "ada.lovelace@x.invalid"), scope)

    [%{changes: changes}] = version_changes("svc_contact_versions", org)

    # The vault field is the token — never the sentinel plaintext.
    assert is_binary(changes["full_name"]) and String.starts_with?(changes["full_name"], "vt_")
    # The plain (non-PII) field is cleartext — proving the token is the VaultField type's
    # dump face, not blanket redaction of every attribute.
    assert changes["label"] == "hello"

    blob = Jason.encode!(changes)
    refute blob =~ "Ada"
    refute blob =~ "Lovelace"
    refute blob =~ "lovelace@x.invalid"

    # Anti-tautology: the "never plaintext" substring scan IS refutable.
    assert_leak_detected!("<td>Ada Lovelace</td>", "Ada")
  end

  # ── c2 · INV-1 token-only diffs (:snapshot — the decisive risk surface) ─────

  test "INV-1 (§6.5 :snapshot, the risk surface): a full-row snapshot of a vault attribute still stores ONLY the vt_ token",
       %{org: org, scope: scope} do
    assert Samen.Info.versioned_mode(Snapshot) == :snapshot

    snap = Samen.Factory.create!(Snapshot, person_attrs(org, "s1", "Grace", "Hopper", "grace@x.invalid"), scope)

    # Update ONLY the plain label. In :snapshot mode the version row reconstructs the
    # FULL prior row — so the (unchanged) vault field IS present in this diff. This is
    # exactly where a naive snapshot could leak plaintext; it must not.
    snap
    |> Ash.Changeset.for_update(:update, %{label: "s2"}, scope: scope)
    |> Ash.update!()

    rows = version_changes("svs_snapshot_versions", org)
    assert length(rows) == 2

    for %{changes: changes} <- rows do
      # full_name present in EVERY snapshot row (full-row reconstruction) and always the token.
      assert is_binary(changes["full_name"]) and String.starts_with?(changes["full_name"], "vt_")
      assert is_binary(changes["emails"]) and String.starts_with?(changes["emails"], "vt_")
      blob = Jason.encode!(changes)
      refute blob =~ "Grace"
      refute blob =~ "Hopper"
      refute blob =~ "grace@x.invalid"
    end

    # The update-snapshot carries the plain field's new value (proving the row really is
    # a full reconstruction, not an empty/dropped diff).
    assert (rows |> List.last() |> Map.get(:changes))["label"] == "s2"

    assert_leak_detected!("<td>Grace Hopper</td>", "Grace")
  end

  # ── c2 · store_action_inputs? off (forever) ─────────────────────────────────

  test "store_action_inputs? is FALSE on every versioned resource and version_action_inputs is not generated" do
    for res <- [Contact, Snapshot] do
      refute AshPaperTrail.Resource.Info.store_action_inputs?(res),
             "#{inspect(res)} must never persist raw action inputs (pre-vault plaintext) — INV-1 §6.3(2)"

      version = Module.concat(res, Version)
      attrs = version |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      refute :version_action_inputs in attrs,
             "the input-storing column must not even exist on #{inspect(version)}"
    end
  end

  # ── c2 · masked-render of a vault diff value ────────────────────────────────

  test "a vault-attribute diff value renders through the masking path as ••••, never the raw vt_ token",
       %{org: org, scope: scope} do
    _ = Samen.Factory.create!(Contact, person_attrs(org, "m", "Ada", "Lovelace", "ada@x.invalid"), scope)
    [%{changes: changes}] = version_changes("svc_contact_versions", org)
    token = changes["full_name"]

    # A history surface renders a vault-attribute diff via the same masking affordance
    # every vault field uses (§6.3(4)): the token wraps to %Masked{} → "••••".
    {:ok, masked} = Samen.Type.VaultField.cast_stored(token, [])
    assert to_string(masked) == "••••"
    refute to_string(masked) =~ "vt_"
    refute to_string(masked) =~ "Ada"
  end

  # ── c6 · four-audit-tiers-disjoint ──────────────────────────────────────────

  test "a versioned + impersonated write produces BOTH a Version row AND exactly one impersonation_write aud_event — never a second row for the version write",
       %{org: org, scope: tenant} do
    # The tenant creates the record (with vault PII) — NOT impersonated, so no
    # impersonation_write row. (An operator plane may never WRITE vaulted plaintext —
    # MC-1/L1 — so the impersonated mutation below is a plain-field update.)
    contact = Samen.Factory.create!(Contact, person_attrs(org, "imp", "Ada", "Lovelace", "ada@x.invalid"), tenant)

    op = Actor.new("operator-#{uniq()}", :operator_support)
    {:ok, session} = Samen.Impersonation.open(op, org, "T119 tiers-disjoint probe")
    {:ok, scope} = Samen.Impersonation.scope(op, org)
    assert Samen.Impersonation.Scope.impersonated?(scope)

    # An impersonated UPDATE of the plain `label` (no vaulted-plaintext write).
    contact
    |> Ash.Changeset.for_update(:update, %{label: "renamed by operator"}, scope: scope)
    |> Ash.update!()

    # E7 business-history tier: both writes produced Version rows (create + update).
    assert version_count("svc_contact_versions", org) == 2

    # §6.6 governance tier: exactly ONE impersonation_write aud_event for the source
    # write. NOT two — the version-row create (same impersonated actor, in the same
    # transaction) must NOT self-audit, or the E7 and §6.6 tiers would double-count.
    imp_rows =
      @repo
      |> Samen.AuditEvent.for_subject(org)
      |> Enum.filter(&(&1.event_type == "impersonation_write"))

    assert length(imp_rows) == 1,
           "exactly one governance row per impersonated write — the version write is not re-audited (tiers disjoint)"

    [row] = imp_rows
    assert row.actor_id == op.id
    assert row.correlation_id == session.id
    assert row.detail =~ "samen:svc:"
    # The version row's object-ref (samen:vcv:...) must NEVER appear as an audited subject.
    refute row.detail =~ "samen:vcv:"

    # The session open (event_type "impersonation") is still its own distinct tier.
    all = Samen.AuditEvent.for_subject(@repo, org)
    assert Enum.any?(all, &(&1.event_type == "impersonation"))
  end

  # ── §6.3(3) guard · :display is leak-safe (every sensitive attr is a vault field) ──

  test "every sensitive? attribute on a versioned resource is a VaultField — so sensitive_attributes :display never versions a non-vault sensitive value in cleartext" do
    for res <- [Contact, Snapshot] do
      offenders =
        res
        |> Ash.Resource.Info.attributes()
        |> Enum.filter(& &1.sensitive?)
        |> Enum.reject(&(&1.type == Samen.Type.VaultField))
        |> Enum.map(& &1.name)

      assert offenders == [],
             "#{inspect(res)} has non-vault sensitive attribute(s) #{inspect(offenders)}; " <>
               "under `sensitive_attributes :display` they would version in cleartext — " <>
               "add them to the paper_trail `ignore_attributes` (ADR-040 §6.3(3))"
    end
  end
end
