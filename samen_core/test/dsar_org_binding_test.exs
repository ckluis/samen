defmodule Samen.DsarOrgBindingTest do
  @moduledoc """
  ADR-046 §4.5 (batch E3 / item D6) — `Samen.Dsar.export_subject/2` is ORG-BOUND and
  gated on the REAL reveal grant model, not a caller-asserted boolean.

  Two guarantees, each proven with a positive control (anti-tautology):

    1. **Cross-org isolation.** An export scoped to org A surfaces ONLY org-A audit-chain
       data for the subject; the SAME subject's org-B chain entries are NEVER surfaced.
       Positive control: the legitimate in-org entry IS surfaced (the filter is the gate,
       not a blanket empty). The `pii_vault` is the global, subject-keyed crypto-shred unit
       (ADR-001), so the org-distinguishable surface is the per-org audit chain — that is
       where the isolation bites, exactly as it does for `Samen.Erasure.shred/2`.

    2. **Grant gating.** On the operator plane a vaulted field resolves to the canonical mask
       string `••••` (`Masked.mask/0`) with NO real grant — even when the caller passes `grant?: true`
       (the old caller-asserted hole, now closed). It resolves PLAINTEXT only with a GENUINE,
       live, distinct-party-approved reveal grant covering the subject, checked against
       `Samen.Reveal.Grants`. The grant is requestor-bound, so a DIFFERENT operator still masks.
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  alias SamenCore.TestRepo, as: Repo
  alias Samen.AuditChain
  alias Samen.Dsar
  alias Samen.Masked
  alias Samen.Reveal.Grants

  @repo Repo

  # The REAL grant model, injected via the `:grant` opt (NOT global config) so this test never
  # races the suite's default `DenyAll`. `:reveal_grant_repo` / `:non_pii_repo` are already the
  # sandbox `TestRepo` in config — we neither set nor delete them (deleting them would break the
  # global reveal/erasure config for every later test).
  @grant Samen.Reveal.Grants

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  defp subj, do: "dsar-org-subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  defp seed(subject_id) do
    {:ok, _} = Samen.Vault.store_field(subject_id, :pii_email, :emails, "alice@example.com", @repo)
    {:ok, _} = Samen.Vault.store_field(subject_id, :pii_name, :full_name, "Alice Anders", @repo)
    :ok
  end

  defp values(bundle), do: Enum.map(bundle.personal_data, & &1.value)

  # DSAR pre-resolves each field to a plane-correct value, so a masked field is the canonical
  # mask STRING (`Masked.mask/0` == MaskingCase `mask/0`), never the plaintext and never a token.
  defp assert_masked_value!(value) do
    assert value == Masked.mask()
    assert to_string(value) == mask()
    refute to_string(value) =~ "vt_"
    value
  end

  defp seed_chain_event(org_id, subject_id, event_type) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      AuditChain.Writer.write(@repo, %{
        org_id: org_id,
        event_type: event_type,
        subject_id: subject_id,
        actor_id: "seed-actor",
        detail: "event=#{event_type}",
        occurred_at: now
      })

    :ok
  end

  describe "cross-org isolation — the audit trail never leaks across orgs" do
    test "an org-A export surfaces org-A events ONLY; the same subject's org-B events are NOT surfaced" do
      s = subj()
      seed(s)

      # The SAME subject has a distinct event on org A's chain and on org B's chain.
      seed_chain_event("org-A", s, "evt_in_org_a")
      seed_chain_event("org-B", s, "evt_in_org_b")

      assert {:ok, bundle_a} = Dsar.export_subject(s, repo: @repo, plane: :tenant, org_id: "org-A")
      types_a = Enum.map(bundle_a.audit_trail, & &1.event_type)
      # Positive control: the legitimate in-org entry IS surfaced (not a blanket empty).
      assert "evt_in_org_a" in types_a
      # Cross-org isolation: org-B's entry for the same subject is NOT surfaced.
      refute "evt_in_org_b" in types_a

      # Mirror: scoped to org B, only org-B events — the isolation is symmetric.
      assert {:ok, bundle_b} = Dsar.export_subject(s, repo: @repo, plane: :tenant, org_id: "org-B")
      types_b = Enum.map(bundle_b.audit_trail, & &1.event_type)
      assert "evt_in_org_b" in types_b
      refute "evt_in_org_a" in types_b
    end
  end

  describe "grant gating — plaintext derives from a REAL grant, never a caller boolean" do
    test "operator export flips MASKED → PLAINTEXT purely by a genuine distinct-party grant" do
      s = subj()
      seed(s)
      requestor = actor()
      approver = actor()

      # RED half: no grant yet → operator export masks (fail-closed). A caller-asserted
      # grant?: true does NOT change this — the old hole is closed.
      assert {:ok, red} =
               Dsar.export_subject(s,
                 repo: @repo,
                 plane: :operator,
                 actor: requestor,
                 grant?: true,
                 grant: @grant,
                 org_id: "org-1"
               )

      for v <- values(red), do: assert_masked_value!(v)

      # Create a GENUINE grant: requestor files, a DISTINCT party approves (distinct-party rule).
      {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "dsar art.15"})
      {:ok, _grant} = Grants.approve(req, %{granted_by: approver})

      # GREEN half: the SAME operator now holds a live grant → plaintext. The only thing that
      # changed is the grant's existence, so the mask was the grant's decision (anti-tautology).
      assert {:ok, green} =
               Dsar.export_subject(s,
                 repo: @repo,
                 plane: :operator,
                 actor: requestor,
                 grant: @grant,
                 org_id: "org-1"
               )

      vals = values(green)
      assert "alice@example.com" in vals
      assert "Alice Anders" in vals

      # The grant is REQUESTOR-bound: a DIFFERENT operator still masks (distinct-party intact).
      other = actor()

      assert {:ok, other_bundle} =
               Dsar.export_subject(s,
                 repo: @repo,
                 plane: :operator,
                 actor: other,
                 grant: @grant,
                 org_id: "org-1"
               )

      for v <- values(other_bundle), do: assert_masked_value!(v)
    end
  end
end
