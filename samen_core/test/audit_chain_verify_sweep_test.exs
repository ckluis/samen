defmodule Samen.AuditChainVerifySweepTest do
  @moduledoc """
  F3.5 — the scheduled audit-chain integrity SWEEP (`AuditChain.verify_all/1` +
  `Samen.AuditChain.VerifyWorker`) and the break-glass reconcile cron worker.

  The sweep re-verifies every org's live hash chain and emits telemetry so a tamper
  (edit/delete) alerts continuously — not only at the next external anchor compare.

  Anti-tautology: the GREEN sweep over clean chains reports `failed == []` (and would
  report a tamper if one existed — proven by the RED test on the SAME machinery). So
  "no tamper" is a real, refutable result.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.AuditChain
  alias Samen.AuditChain.Entry

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {:ok, org: "org-#{System.unique_integer([:positive])}"}
  end

  defp append!(org) do
    {:ok, %Entry{} = e} =
      AuditChain.append(
        %{
          org_id: org,
          event_type: "reveal",
          subject_id: "subj-#{System.unique_integer([:positive])}",
          actor_id: "op-1",
          detail: "event=granted"
        },
        repo: Repo
      )

    e
  end

  defp attach_telemetry(events) do
    ref = make_ref()
    parent = self()
    handler = "test-#{inspect(ref)}"

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    ref
  end

  describe "verify_all/1 — the green sweep" do
    test "over clean chains reports zero failures and emits the summary signal", %{org: org} do
      attach_telemetry([[:samen, :audit_chain, :verify], [:samen, :audit_chain, :tamper]])

      other = "org-#{System.unique_integer([:positive])}"
      append!(org)
      append!(org)
      append!(other)

      summary = AuditChain.verify_all(repo: Repo)
      assert summary.failed == []
      assert summary.orgs >= 2
      assert summary.verified == summary.orgs

      assert_receive {:telemetry, [:samen, :audit_chain, :verify], %{failed: 0} = m, _}
      assert m.verified == m.orgs
      # No tamper signal on a clean sweep (positive control for the RED test below).
      refute_received {:telemetry, [:samen, :audit_chain, :tamper], _, _}
    end
  end

  describe "verify_all/1 — the RED sweep detects tamper + emits the tamper signal" do
    test "an edited entry is caught; the org appears in failed + a tamper event fires", %{org: org} do
      attach_telemetry([[:samen, :audit_chain, :verify], [:samen, :audit_chain, :tamper]])

      _e0 = append!(org)
      e1 = append!(org)
      _e2 = append!(org)

      # Model an attacker with raw DB access: disable the append-only trigger, edit a
      # payload, re-enable. The stored hash no longer matches the recomputed hash.
      Repo.query!("ALTER TABLE aud_chain DISABLE TRIGGER aud_chain_append_only_tg")
      Repo.query!("UPDATE aud_chain SET ach_detail = 'TAMPERED' WHERE ach_id = $1", [Ecto.UUID.dump!(e1.id)])
      Repo.query!("ALTER TABLE aud_chain ENABLE TRIGGER aud_chain_append_only_tg")

      summary = AuditChain.verify_all(repo: Repo)

      assert Enum.any?(summary.failed, fn {o, {reason, seq}} ->
               o == org and reason == :hash_mismatch and seq == 1
             end)

      assert_receive {:telemetry, [:samen, :audit_chain, :tamper], %{seq: 1}, %{org_id: ^org, reason: :hash_mismatch}}
      assert_receive {:telemetry, [:samen, :audit_chain, :verify], %{failed: f}, _} when f >= 1
    end
  end

  describe "VerifyWorker.perform/1 — thin, returns :ok (telemetry is the alert channel)" do
    test "returns :ok on clean chains", %{org: org} do
      append!(org)
      assert :ok = Samen.AuditChain.VerifyWorker.perform(%Oban.Job{id: 1, args: %{}})
    end

    test "returns :ok even on tamper (a tamper is not a retryable infra fault)", %{org: org} do
      _e0 = append!(org)
      e1 = append!(org)

      Repo.query!("ALTER TABLE aud_chain DISABLE TRIGGER aud_chain_append_only_tg")
      Repo.query!("UPDATE aud_chain SET ach_detail = 'X' WHERE ach_id = $1", [Ecto.UUID.dump!(e1.id)])
      Repo.query!("ALTER TABLE aud_chain ENABLE TRIGGER aud_chain_append_only_tg")

      assert :ok = Samen.AuditChain.VerifyWorker.perform(%Oban.Job{id: 2, args: %{}})
    end
  end

  describe "default_crontab wires the F3.5 sweeps" do
    test "the verify + reconcile workers are on the crontab" do
      workers = Enum.map(Samen.Jobs.default_crontab(), fn {_cron, w} -> w end)
      assert Samen.AuditChain.VerifyWorker in workers
      assert Samen.BreakGlass.ReconcileWorker in workers
    end
  end
end
