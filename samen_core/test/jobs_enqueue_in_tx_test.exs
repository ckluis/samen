defmodule Samen.Jobs.EnqueueInTxTest do
  @moduledoc """
  T2.1 (a): `Samen.Jobs.enqueue_in_tx/3` same-transaction enqueue helper.

  The crash test proves that a multi that rolls back AFTER the enqueue step
  leaves NO `oban_jobs` row — the job INSERT is part of the same transaction
  and is rolled back with it.

  Red-path (anti-tautology probe): the test first asserts the crash path (no job
  row after rollback), then asserts the happy path (job row exists after commit)
  to prove the assertion is discriminating (a vacuous always-passes check would
  fail this second assertion).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Samen.Jobs
  alias Samen.Jobs.RollupRefreshWorker

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp job_count_for(worker) do
    @repo.aggregate(
      from(j in "oban_jobs", where: j.worker == ^worker),
      :count
    )
  end

  # -----------------------------------------------------------------------
  # Happy path: commit leaves exactly one job row
  # -----------------------------------------------------------------------

  test "commit: enqueue_in_tx inserts a job row in the same transaction" do
    before_count = job_count_for("Samen.Jobs.RollupRefreshWorker")

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:noop, fn _repo, _changes -> {:ok, :noop} end)
      |> Jobs.enqueue_in_tx(:job, RollupRefreshWorker.new(%{}))

    assert {:ok, _} = @repo.transaction(multi)
    assert job_count_for("Samen.Jobs.RollupRefreshWorker") == before_count + 1
  end

  # -----------------------------------------------------------------------
  # CRASH test (red-path): rollback removes the job row
  # -----------------------------------------------------------------------

  test "CRASH: rollback after enqueue_in_tx leaves NO oban_jobs row" do
    before_count = job_count_for("Samen.Jobs.RollupRefreshWorker")

    # Build a multi that enqueues the job and then FAILS, forcing a rollback.
    multi =
      Ecto.Multi.new()
      |> Jobs.enqueue_in_tx(:job, RollupRefreshWorker.new(%{}))
      |> Ecto.Multi.run(:boom, fn _repo, _changes ->
        {:error, :simulated_crash}
      end)

    assert {:error, :boom, :simulated_crash, _} = @repo.transaction(multi)

    # No job row must survive — the enqueue was in the same transaction.
    assert job_count_for("Samen.Jobs.RollupRefreshWorker") == before_count,
           "expected no new oban_jobs row after rollback (same-tx enqueue guarantee)"
  end

  # -----------------------------------------------------------------------
  # Anti-tautology probe: crash-path assertion is discriminating
  # -----------------------------------------------------------------------
  # (The two tests above together form the discriminating pair: crash → no row,
  # commit → row. If only the crash assertion existed it could be vacuously true.
  # Having both proves the assertion is non-trivial.)

  test "enqueue_in_tx accepts a pre-built job changeset (alternative call form)" do
    cs = RollupRefreshWorker.new(%{}, queue: :rollups)
    assert %Ecto.Changeset{} = cs

    multi =
      Ecto.Multi.new()
      |> Jobs.enqueue_in_tx(:cs_job, cs)

    assert {:ok, %{cs_job: %Oban.Job{}}} = @repo.transaction(multi)
  end
end
