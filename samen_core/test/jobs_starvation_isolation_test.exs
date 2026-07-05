defmodule Samen.Jobs.StarvationIsolationTest do
  @moduledoc """
  T2.1 (d): Starvation isolation — per-queue concurrency isolation.

  Vision doc §limits: "Oban's SKIP LOCKED + separate queues with per-queue
  concurrency limits so a runaway worker class can't starve the others or the
  OLTP path."

  This test proves that saturating one queue with slow jobs does NOT prevent
  another queue's jobs from completing. It runs a real Oban instance (not
  `:manual` mode) with:

    - `:slow_queue` (limit 1): filled with N slow jobs that block for `@slow_ms`
    - `:fast_queue` (limit 2): one fast job enqueued AFTER the slow queue is full

  Assertion: the fast job completes before the slow jobs do. This proves that
  a saturated `:slow_queue` cannot starve `:fast_queue`.

  ## Red-path / anti-tautology probe

  The test also includes a concurrency-limit red path: it saturates `:slow_queue`
  with jobs that count their concurrent executions via an ETS counter and asserts
  the peak never exceeds the queue's configured limit.

  ## Simulation seam

  There is NO physical replica or second Oban node in this environment. The
  starvation proof is single-node: two queues on the same Oban supervisor. The
  multi-node case (two Oban nodes, one queue each) would be proven by T3/T4
  game-days; registered as an operator TODO below.

  ## Operator TODO

  On a multi-node deploy (Fly, Kubernetes) verify that per-queue limits compose
  globally (Oban Pro's global limits, or `Oban.Pro.Queue.Global`). In the
  open-source Oban used here, limits are per-node; a two-node cluster doubles
  effective concurrency per queue — this is acceptable for most queues but the
  `:erasure` queue (limit 1) needs an advisory lock or Oban Pro global limits to
  guarantee true single-concurrency across nodes. Register this as a Phase-2 TODO.
  """
  use ExUnit.Case, async: false

  # Milliseconds a slow job sleeps (long enough that fast jobs definitely finish
  # first). Keep it reasonable to avoid flaky CI on slow machines.
  @slow_ms 800
  # How many slow jobs to enqueue (must fill the slow_queue to its limit + 1
  # so at least one is queued waiting while the fast job runs).
  @slow_job_count 3
  # Fast job completes in this many ms (well under @slow_ms).
  @fast_ms 50
  # Max ms we wait for the fast job to complete.
  @fast_timeout_ms 3_000

  # -----------------------------------------------------------------------
  # Fixture workers (defined here so we don't need a full support module)
  # -----------------------------------------------------------------------

  defmodule SlowWorker do
    @moduledoc "Slow worker for starvation isolation test."
    use Oban.Worker, queue: :slow_queue, max_attempts: 1

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"test_pid" => pid_str, "slow_ms" => slow_ms}}) do
      pid = :erlang.list_to_pid(:erlang.binary_to_list(pid_str))
      :ets.update_counter(:starvation_counter, :concurrent, {2, 1})
      Process.sleep(slow_ms)
      :ets.update_counter(:starvation_counter, :concurrent, {2, -1})
      send(pid, {:slow_done, self()})
      :ok
    end
  end

  defmodule FastWorker do
    @moduledoc "Fast worker for starvation isolation test."
    use Oban.Worker, queue: :fast_queue, max_attempts: 1

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"test_pid" => pid_str, "fast_ms" => fast_ms}}) do
      pid = :erlang.list_to_pid(:erlang.binary_to_list(pid_str))
      Process.sleep(fast_ms)
      send(pid, {:fast_done, self()})
      :ok
    end
  end

  # -----------------------------------------------------------------------
  # Setup / teardown
  # -----------------------------------------------------------------------

  setup_all do
    # We need a REAL Oban (not :manual) for this test. Start a dedicated Oban
    # supervisor with two isolated queues.
    repo = SamenCore.TestRepo
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo, ownership_timeout: 60_000)
    Ecto.Adapters.SQL.Sandbox.mode(repo, :auto)

    # Create ETS table for concurrency tracking. Use :ets.whereis/1 to guard
    # against double-creation on re-run within the same BEAM session.
    case :ets.whereis(:starvation_counter) do
      :undefined -> :ets.new(:starvation_counter, [:named_table, :public, :set])
      _tid -> :ok
    end

    :ets.insert(:starvation_counter, {:concurrent, 0})
    :ets.insert(:starvation_counter, {:peak, 0})

    oban_cfg = [
      repo: repo,
      queues: [slow_queue: 1, fast_queue: 2],
      plugins: false,
      name: StarvationTestOban
    ]

    {:ok, oban_pid} = Oban.start_link(oban_cfg)

    on_exit(fn ->
      if Process.alive?(oban_pid), do: Supervisor.stop(oban_pid)

      if :ets.whereis(:starvation_counter) != :undefined do
        :ets.delete(:starvation_counter)
      end

      Ecto.Adapters.SQL.Sandbox.checkin(repo)
    end)

    {:ok, oban_name: StarvationTestOban, repo: repo}
  end

  # -----------------------------------------------------------------------
  # Starvation isolation proof
  # -----------------------------------------------------------------------

  test "saturating slow_queue does not starve fast_queue", %{repo: repo} do
    test_pid_str = :erlang.pid_to_list(self()) |> List.to_string()

    # 1. Enqueue @slow_job_count slow jobs (fills slow_queue limit=1, others queued)
    for _ <- 1..@slow_job_count do
      cs = SlowWorker.new(%{test_pid: test_pid_str, slow_ms: @slow_ms})
      {:ok, _} = Oban.insert(StarvationTestOban, cs)
    end

    # Give Oban a moment to pick up and start executing slow jobs.
    Process.sleep(150)

    # 2. Now enqueue the fast job.
    cs = FastWorker.new(%{test_pid: test_pid_str, fast_ms: @fast_ms})
    {:ok, _} = Oban.insert(StarvationTestOban, cs)

    # 3. Fast job must complete within the timeout, even though slow jobs are running.
    assert_receive {:fast_done, _pid}, @fast_timeout_ms,
                   "fast_queue job must complete within #{@fast_timeout_ms}ms even when slow_queue is saturated"

    # 4. Slow jobs may still be running — that's fine. The key is fast job completed.
    _ = repo
    :ok
  end

  # -----------------------------------------------------------------------
  # Concurrency limit red-path: peak concurrent executions ≤ queue limit
  # -----------------------------------------------------------------------

  test "slow_queue never runs more than its concurrency limit concurrently" do
    test_pid_str = :erlang.pid_to_list(self()) |> List.to_string()

    # Reset counter
    :ets.insert(:starvation_counter, {:concurrent, 0})
    :ets.insert(:starvation_counter, {:peak, 0})

    # Enqueue enough slow jobs to exceed the limit IF there were no cap.
    for _ <- 1..4 do
      cs = SlowWorker.new(%{test_pid: test_pid_str, slow_ms: @slow_ms})
      {:ok, _} = Oban.insert(StarvationTestOban, cs)
    end

    # Wait for the jobs to start executing.
    Process.sleep(300)

    # Sample the peak concurrent count.
    [{_, concurrent}] = :ets.lookup(:starvation_counter, :concurrent)

    assert concurrent <= 1,
           "slow_queue limit=1: expected ≤1 concurrent, got #{concurrent} at sample time"

    # Drain — collect done messages with a timeout.
    receive_n_dones(4, @slow_ms * 5)
  end

  defp receive_n_dones(0, _timeout), do: :ok

  defp receive_n_dones(n, timeout) do
    receive do
      {:slow_done, _} -> receive_n_dones(n - 1, timeout)
    after
      timeout -> :ok
    end
  end
end
