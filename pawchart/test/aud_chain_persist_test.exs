defmodule PawChart.AudChainPersistTest do
  @moduledoc """
  O2 + O7 (ADR-045 §4.3 / panel-4 O2, O7): proof that PawChart's tamper-evident
  audit chain now EXISTS and appends PERSIST — and that the `aud_event` tier is
  wired to PawChart's OWN config key, not driftwood's.

  Before this fix PawChart shipped NO `aud_chain` table at all, so every
  `Samen.AuditChain.append/2` raised `relation "aud_chain" does not exist`, and
  the DSAR/reveal writers swallowed the failure — non-repudiation was silently
  broken in the vet vertical. These tests drive the REAL `Samen.AuditChain`
  against `PawChart.Repo` (the same repo the operator-plane/DSAR writers use).

  Structure (house rule: every guarantee ships a positive control so no assertion
  is vacuous):

    * GREEN — an append lands, is retrievable from the table, and the chain
      verifies; the tenant view surfaces the persisted entries.
    * POSITIVE CONTROL — a distinct org with NO appends verifies as an empty
      genesis chain (`head_seq: -1`, `entries: 0`), so the GREEN "entries: 2" is a
      real, discriminating result and not something that passes on any input.
    * WIRING (O7) — the `aud_event` and `aud_chain` migrations read pawchart's own
      `:pawchart` otp_app for `:aud_event_app_role`, never driftwood's `:driftwood`
      (the copy-paste that made pawchart's knob unreachable).
  """
  use PawChart.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Samen.AuditChain
  alias Samen.AuditChain.{Entry, TenantView}

  @repo PawChart.Repo

  # A real tenant (clinic) org — never the reserved "__global__" system chain.
  defp clinic_org, do: "pc-clinic-#{System.unique_integer([:positive])}"

  defp append!(org, attrs \\ %{}) do
    base = %{
      org_id: org,
      event_type: "reveal",
      subject_id: "subj-#{System.unique_integer([:positive])}",
      actor_id: "op-pawchart-platform",
      detail: "event=granted"
    }

    assert {:ok, %Entry{} = e} = AuditChain.append(Map.merge(base, attrs), repo: @repo)
    e
  end

  describe "GREEN — pawchart audit-chain appends persist and verify" do
    test "an append PERSISTS and is retrievable from the aud_chain table" do
      org = clinic_org()

      e0 = append!(org, %{detail: "event=reveal seq0", subject_id: "subj-pc-A"})
      e1 = append!(org, %{detail: "event=erasure seq1", subject_id: "subj-pc-B"})

      # Persisted: the rows are physically readable back from PawChart.Repo (not a
      # fabricated {:ok, _} — the row is on the table with the exact payload).
      reloaded = @repo.get!(Entry, e0.id)
      assert reloaded.org_id == org
      assert reloaded.seq == 0
      assert reloaded.detail == "event=reveal seq0"
      assert reloaded.subject_id == "subj-pc-A"

      assert e1.seq == 1
      assert e1.prior_hash == e0.hash

      count = @repo.aggregate(from(e in Entry, where: e.org_id == ^org), :count, :id)
      assert count == 2

      # And the persisted chain verifies (hash-linked, no gaps).
      assert {:ok, %{entries: 2}} = AuditChain.verify_chain(org, repo: @repo)
    end

    test "the tenant view surfaces the persisted chain and reports it verified" do
      org = clinic_org()
      append!(org)
      append!(org)

      assert {:ok, view} = TenantView.for_org(org, repo: @repo)
      assert view.chain_verified == true
      assert view.chain_error == nil
      assert view.head_seq == 1
      assert length(view.entries) == 2
      assert Enum.map(view.entries, & &1.seq) == [0, 1]
    end

    test "POSITIVE CONTROL: an org with NO appends verifies as an empty genesis chain" do
      empty_org = clinic_org()

      # Non-vacuous: verify_chain runs against the REAL table (it must exist) and
      # returns the empty-chain result, so the GREEN "entries: 2" above is a real
      # discriminating value, not something true on every input.
      assert {:ok, %{entries: 0, head_seq: -1}} = AuditChain.verify_chain(empty_org, repo: @repo)
    end
  end

  describe "WIRING (O7) — the audit migrations read pawchart's OWN config key" do
    @aud_event_migration Path.expand(
                           "../priv/repo/migrations/20260705020000_aud_event.exs",
                           __DIR__
                         )
    @aud_chain_migration Path.expand(
                           "../priv/repo/migrations/20260807110500_aud_chain.exs",
                           __DIR__
                         )

    # ADR-045 §4.2 (O4 fold-in): the role is now DERIVED at migration time via the shared
    # `Samen.OperatorPlane.Migration.app_role!/2` helper (knob → repo :username → RAISE) instead
    # of `Application.compile_env(:pawchart, :aud_event_app_role, "clank")`. The O7 guarantee is
    # UNCHANGED — the derivation still reads pawchart's OWN otp_app (`:pawchart`, never
    # driftwood's `:driftwood`) — so these wiring proofs now assert the helper call names
    # `:pawchart` / `PawChart.Repo` rather than the (removed) `compile_env(:pawchart, ...)` form.
    test "aud_event derives off :pawchart (never driftwood's :driftwood) for :aud_event_app_role" do
      src = File.read!(@aud_event_migration)

      assert src =~ "Samen.OperatorPlane.Migration.app_role!(:pawchart, PawChart.Repo)",
             "pawchart aud_event migration must derive the role off pawchart's OWN otp_app"

      refute src =~ "app_role!(:driftwood",
             "pawchart aud_event migration must NOT derive off driftwood's otp_app (O7)"

      refute src =~ ~r/compile_env\(:driftwood/,
             "pawchart aud_event migration must NOT read driftwood's compile_env key (O7)"
    end

    test "aud_chain derives off :pawchart for :aud_event_app_role" do
      src = File.read!(@aud_chain_migration)

      assert src =~ "Samen.OperatorPlane.Migration.app_role!(:pawchart, PawChart.Repo)",
             "pawchart aud_chain migration must derive the role off pawchart's OWN otp_app"

      refute src =~ "app_role!(:driftwood",
             "pawchart aud_chain migration must NOT derive off driftwood's otp_app"

      refute src =~ ~r/compile_env\(:driftwood/,
             "pawchart aud_chain migration must NOT read driftwood's compile_env key"
    end
  end
end
