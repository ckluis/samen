defmodule Samen.SuspensionAsymmetryTest do
  @moduledoc """
  Suspend REMOVES privilege, clear RESTORES it, and the two answer to the audit tables differently:

    * `suspend/1` commits the suspension FIRST; a failed audit write is reported and parked on the break-glass
      local hash chain (the deferred-anchor precedent) for `Reconciliation` to anchor later. The caller learns the
      suspension landed (`{:ok, row}`, `row.audit == :pending`).
    * `clear/2` stays atomic with its audit entry and fails closed.
    * `Budget.record_and_check/1` never crashes: an over-budget operator whose suspension cannot be written gets
      `{:error, :suspend_failed}` and the reveal in progress is refused.

  Faults are real `DBConnection.ConnectionError`s from `Samen.FaultRepo` (`:probe` = the audit chain probe, `:insert`
  = the suspension row), not mocks of the code under test.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Samen.BreakGlass
  alias Samen.BreakGlass.{Budget, LocalAudit, Reconciliation}
  alias Samen.OperatorPlane.{Actor, Suspension, SuspensionRow}
  alias Samen.FaultRepo

  @repo SamenCore.TestRepo

  # A vault that must never be reached by a refused reveal.
  defmodule TripwireVault do
    def reveal(_masked, _repo, _opts) do
      send(self(), :vault_reached)
      {:ok, "plaintext"}
    end
  end

  setup do
    Samen.TestSandbox.shared!(@repo)
    FaultRepo.heal()
    prior = Application.get_env(:samen_core, :break_glass_breadth_budget)
    Application.put_env(:samen_core, :break_glass_breadth_budget, 1)

    path = Path.join(System.tmp_dir!(), "susp_test_#{System.unique_integer([:positive])}.local")
    File.rm_rf!(path)

    on_exit(fn ->
      FaultRepo.heal()
      Application.put_env(:samen_core, :break_glass_breadth_budget, prior)
      File.rm_rf!(path)
    end)

    {:ok, path: path}
  end

  defp op_id, do: "op-#{System.unique_integer([:positive])}"

  defp audit_events(subject_id) do
    @repo.all(
      from(e in Samen.AuditEvent,
        where: e.subject_id == ^subject_id and e.event_type == "operator_suspension",
        select: e.detail
      )
    )
  end

  defp over_budget(op, repo, path) do
    for s <- ["a", "b"] do
      Budget.record_and_check(%{
        operator_id: op,
        subject_id: "#{s}-#{System.unique_integer([:positive])}",
        repo: repo,
        local_audit_path: path
      })
    end
  end

  describe "suspend/1 does not depend on the audit tables" do
    test "audit down + over budget: the operator IS suspended, no crash, the audit entry is pending, reconcile writes it",
         %{path: path} do
      op = op_id()
      FaultRepo.fail([:probe])

      assert [{:ok, 1}, {:suspended, 2}] = over_budget(op, FaultRepo, path)

      FaultRepo.heal()
      assert Suspension.suspended?(op, repo: @repo)
      assert audit_events(op) == []

      # Pending audit is durable on the local chain, with the suspension's facts.
      assert {:ok, [entry]} = LocalAudit.entries(path: path)
      assert entry.action == "operator_suspended"
      assert entry.subject_id == op
      assert entry.reason =~ "breadth budget exceeded"
      assert Reconciliation.unanchored_count(repo: @repo, path: path) == 1

      # Later (audit back): the reconciler writes the audit entry exactly once.
      assert {:ok, %{anchored: 1}} = Reconciliation.reconcile(repo: @repo, path: path)
      assert [detail] = audit_events(op)
      assert detail =~ "event=operator_suspended"
      assert detail =~ "breadth budget exceeded"
      assert {:ok, %{anchored: 0, already: 1}} = Reconciliation.reconcile(repo: @repo, path: path)
      assert length(audit_events(op)) == 1
    end

    test "suspend/1 reports the pending audit on the returned row, and reports the failure", %{path: path} do
      op = op_id()
      FaultRepo.fail([:probe])

      assert {:ok, %SuspensionRow{audit: :pending, operator_id: ^op}} =
               Suspension.suspend(%{operator_id: op, reason: "x", repo: FaultRepo, local_audit_path: path})
    end

    test "positive control: audit up → :written, an audit event, nothing parked locally", %{path: path} do
      op = op_id()

      assert {:ok, %SuspensionRow{audit: :written}} =
               Suspension.suspend(%{operator_id: op, reason: "x", repo: FaultRepo, local_audit_path: path})

      assert Suspension.suspended?(op, repo: @repo)
      assert [_] = audit_events(op)
      refute File.exists?(path)
    end

    test "audit down AND the local park fails: still suspended, flagged :lost", %{path: path} do
      op = op_id()
      FaultRepo.fail([:probe])
      # a directory where the file should be: the local append cannot open it
      File.mkdir_p!(path)

      assert {:ok, %SuspensionRow{audit: :lost}} =
               Suspension.suspend(%{operator_id: op, reason: "x", repo: FaultRepo, local_audit_path: path})

      assert Suspension.suspended?(op, repo: @repo)
    end

    test "suspension table down: {:error, :unavailable}, nothing suspended", %{path: path} do
      op = op_id()
      FaultRepo.fail([:insert])

      assert {:error, :unavailable} =
               Suspension.suspend(%{operator_id: op, reason: "x", repo: FaultRepo, local_audit_path: path})

      FaultRepo.heal()
      refute Suspension.suspended?(op, repo: @repo)
    end

    test "clear/2 stays atomic with its audit entry: audit down → error, the suspension is NOT cleared" do
      op = op_id()
      assert {:ok, _} = Suspension.suspend(%{operator_id: op, reason: "x", repo: @repo})

      FaultRepo.fail([:probe])
      assert {:error, :audit_unavailable} = Suspension.clear(op, %{repo: FaultRepo})
      FaultRepo.heal()
      assert Suspension.suspended?(op, repo: @repo)

      # positive control: audit up → cleared.
      assert {:ok, %SuspensionRow{}} = Suspension.clear(op, %{repo: @repo})
      refute Suspension.suspended?(op, repo: @repo)
    end
  end

  describe "Budget.record_and_check/1 never crashes" do
    test "over budget and the suspension cannot be written: {:error, :suspend_failed}, reported", %{path: path} do
      op = op_id()
      test_pid = self()
      handler = "susp-fail-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:samen, :core, :read, :error],
        fn _e, _m, meta, _ -> send(test_pid, {:failure, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      FaultRepo.fail([:insert])
      assert [{:ok, 1}, {:error, :suspend_failed}] = over_budget(op, FaultRepo, path)
      assert_receive {:failure, %{read: :budget_auto_suspend}}
    end
  end

  describe "BreakGlass.reveal/1 under those failures" do
    defp reveal_req(op, repo, path) do
      %{
        operator: Actor.new(op, :operator_break_glass),
        subject_id: "subj-#{System.unique_integer([:positive])}",
        reason: "PagerDuty INC-42: locked-out user support escalation",
        masked: Samen.Masked.new("vt_unused", :emails),
        action: :reveal_email,
        resource: SamenCore.Support.RevealDomain.RevealPerson,
        org_id: "org-#{System.unique_integer([:positive])}",
        repo: repo,
        vault: TripwireVault,
        local_audit_path: path
      }
    end

    test "audit down, over budget: the reveal is denied :budget_exceeded (no crash) and the operator is suspended",
         %{path: path} do
      op = op_id()
      assert {:ok, _} = BreakGlass.reveal(reveal_req(op, @repo, path))
      FaultRepo.fail([:probe])

      assert {:error, :budget_exceeded} = BreakGlass.reveal(reveal_req(op, FaultRepo, path))
      FaultRepo.heal()
      assert Suspension.suspended?(op, repo: @repo)
    end

    test "suspension table down, over budget: the reveal is REFUSED and never reaches the vault", %{path: path} do
      op = op_id()
      assert {:ok, _} = BreakGlass.reveal(reveal_req(op, @repo, path))
      assert_received :vault_reached
      FaultRepo.fail([:insert])

      assert {:error, :suspension_failed} = BreakGlass.reveal(reveal_req(op, FaultRepo, path))
      refute_received :vault_reached
    end
  end

  describe "reveal vs suspension filing" do
    test "a reveal-shaped entry named operator_suspended anchors as break_glass, a real one as operator_suspension",
         %{path: path} do
      op = op_id()
      org = "org-#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               LocalAudit.append(
                 %{org_id: org, subject_id: op, actor_id: op, reason: "reveal", resource: "r", action: "operator_suspended"},
                 path: path
               )

      assert {:ok, %{anchored: 1}} = Reconciliation.reconcile(repo: @repo, path: path)
      assert [%{event_type: "break_glass"}] = events_for(op)

      # positive control: the genuine deferred suspension is still filed as the suspension event
      FaultRepo.fail([:probe])
      op2 = op_id()
      assert {:ok, %{audit: :pending}} = Suspension.suspend(%{operator_id: op2, reason: "x", repo: FaultRepo, local_audit_path: path})
      FaultRepo.heal()
      assert {:ok, %{anchored: 1}} = Reconciliation.reconcile(repo: @repo, path: path)
      assert [%{event_type: "operator_suspension"}] = events_for(op2)
    end

    test "BreakGlass.reveal/1 refuses the reserved action name", %{path: path} do
      req = %{reveal_req_for(op_id(), @repo, path) | action: :operator_suspended}
      assert {:error, :reserved_action} = BreakGlass.reveal(req)
      refute_received :vault_reached
    end

    test "idempotent re-suspend reports audit :unknown, not :written", %{path: path} do
      op = op_id()
      FaultRepo.fail([:probe])
      assert {:ok, %{audit: :pending}} = Suspension.suspend(%{operator_id: op, reason: "x", repo: FaultRepo, local_audit_path: path})
      FaultRepo.heal()
      assert {:ok, %{audit: :unknown}} = Suspension.suspend(%{operator_id: op, reason: "x", repo: @repo, local_audit_path: path})
    end
  end

  defp events_for(subject_id) do
    @repo.all(from(e in Samen.AuditEvent, where: e.subject_id == ^subject_id, select: %{event_type: e.event_type}))
  end

  defp reveal_req_for(op, repo, path) do
    %{
      operator: Actor.new(op, :operator_break_glass),
      subject_id: "subj-#{System.unique_integer([:positive])}",
      reason: "PagerDuty INC-42: locked-out user support escalation",
      masked: Samen.Masked.new("vt_unused", :emails),
      action: :reveal_email,
      resource: SamenCore.Support.RevealDomain.RevealPerson,
      org_id: "org-#{System.unique_integer([:positive])}",
      repo: repo,
      vault: TripwireVault,
      local_audit_path: path
    }
  end
end
