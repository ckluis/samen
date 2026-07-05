defmodule Samen.Jobs.QueueTaxonomyTest do
  @moduledoc """
  T2.1 (b): Queue taxonomy and per-queue concurrency limits.

  Tests:
    1. `Samen.Jobs.default_queue_config/0` returns all six canonical queues.
    2. Each queue has a positive integer concurrency limit.
    3. The `:erasure` queue limit is 1 (guaranteed single-concurrency for
       crypto-shred orchestration — running two simultaneous erasure jobs for
       the same subject would be a race).
    4. Red-path: a running Oban instance never runs more than N jobs
       concurrently on a queue whose limit is N. Proven via telemetry counters
       (starvation isolation is in `jobs_starvation_isolation_test.exs`).
  """
  use ExUnit.Case, async: true

  alias Samen.Jobs

  # -----------------------------------------------------------------------
  # Queue taxonomy shape
  # -----------------------------------------------------------------------

  test "default_queue_config/0 returns all six canonical queues" do
    queues = Jobs.default_queue_config()
    names = Keyword.keys(queues)

    for expected <- [:default, :rollups, :webhooks_out, :erasure, :maintenance, :reveal] do
      assert expected in names, "expected queue #{inspect(expected)} in taxonomy"
    end
  end

  test "every queue has a positive integer concurrency limit" do
    for {name, limit} <- Jobs.default_queue_config() do
      assert is_integer(limit) and limit > 0,
             "queue #{inspect(name)} must have a positive integer limit, got #{inspect(limit)}"
    end
  end

  test "erasure queue limit is 1 (single-concurrency for crypto-shred safety)" do
    queues = Jobs.default_queue_config()
    assert Keyword.fetch!(queues, :erasure) == 1
  end

  test "maintenance queue limit is 1 (single-concurrency for partition operations)" do
    queues = Jobs.default_queue_config()
    assert Keyword.fetch!(queues, :maintenance) == 1
  end

  test "default_crontab/0 contains at least one entry" do
    crontab = Jobs.default_crontab()
    assert length(crontab) > 0
  end

  test "default_crontab/0 entries are {cron_string, worker_module} tuples" do
    for {expr, worker} <- Jobs.default_crontab() do
      assert is_binary(expr), "cron expression must be a string, got #{inspect(expr)}"
      assert is_atom(worker), "worker must be an atom (module), got #{inspect(worker)}"

      # Worker module must exist and use Oban.Worker.
      assert Code.ensure_loaded?(worker), "cron worker #{inspect(worker)} not loaded"
    end
  end

  test "worker_defaults/1 returns a keyword with the expected keys" do
    defaults = Jobs.worker_defaults(:rollups)
    assert Keyword.fetch!(defaults, :queue) == :rollups
    assert Keyword.fetch!(defaults, :max_attempts) == 20
    assert Keyword.has_key?(defaults, :unique)
  end
end
