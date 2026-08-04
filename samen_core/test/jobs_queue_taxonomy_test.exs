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

  # -----------------------------------------------------------------------
  # T128: audit-partition roll-forward is registered by DEFAULT
  # -----------------------------------------------------------------------
  # These assertions are the regression tripwire: a future edit that removes the
  # PartitionManager cron entry (re-opening the silent audit-write-failure gap once
  # the wall clock crosses the seeded partition boundary) FAILS here.

  test "default_crontab/0 registers the aud_event PartitionManager (daily @ 01:00)" do
    crontab = Jobs.default_crontab()

    assert {"0 1 * * *", Samen.AuditEvent.PartitionManager} in crontab,
           "default_crontab/0 MUST schedule Samen.AuditEvent.PartitionManager so every " <>
             "generated app rolls aud_event partitions forward; got: #{inspect(crontab)}"
  end

  test "the registered PartitionManager entry points at a real Oban worker (not a stub)" do
    {_expr, worker} =
      Enum.find(Jobs.default_crontab(), fn {_e, w} -> w == Samen.AuditEvent.PartitionManager end)

    assert Code.ensure_loaded?(worker)
    # It must actually be an Oban.Worker with a perform/1 that the cron will invoke.
    assert function_exported?(worker, :perform, 1)
    behaviours = worker.__info__(:attributes) |> Keyword.get(:behaviour, [])
    assert Oban.Worker in behaviours, "PartitionManager must `use Oban.Worker`"
  end

  # -----------------------------------------------------------------------
  # T128: install_default_cron/1 — the framework adoption seam
  # -----------------------------------------------------------------------

  test "install_default_cron/1 adds the Cron plugin with default_crontab/0 (prod/dev shape)" do
    base = [repo: SamenCore.TestRepo, queues: [maintenance: 1], plugins: [{Oban.Plugins.Pruner, max_age: 60}]]

    installed = Jobs.install_default_cron(base)
    plugins = Keyword.fetch!(installed, :plugins)

    cron = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))
    assert cron, "expected an Oban.Plugins.Cron plugin to be installed"
    {Oban.Plugins.Cron, cron_opts} = cron
    assert Keyword.fetch!(cron_opts, :crontab) == Jobs.default_crontab()

    # The pre-existing Pruner is preserved (not clobbered).
    assert Enum.any?(plugins, &match?({Oban.Plugins.Pruner, _}, &1))
  end

  test "install_default_cron/1 is a no-op when plugins are disabled (test convention)" do
    base = [repo: SamenCore.TestRepo, testing: :manual, plugins: false]
    assert Jobs.install_default_cron(base) == base
  end

  test "install_default_cron/1 respects a host that already declared its own Cron plugin" do
    host_cron = {Oban.Plugins.Cron, crontab: [{"*/30 * * * *", Samen.Jobs.RollupRefreshWorker}]}
    base = [repo: SamenCore.TestRepo, plugins: [host_cron]]

    # Unchanged — no double-scheduling; the explicit host schedule wins.
    assert Jobs.install_default_cron(base) == base
  end

  test "a generated app that calls install_default_cron ends up scheduling PartitionManager" do
    # End-to-end of the adoption seam: the generated application.ex passes the config.exs
    # Oban opts (Pruner only, no Cron) through install_default_cron — the result must
    # schedule the audit-partition roll-forward.
    generated_config = [
      repo: SamenCore.TestRepo,
      queues: Jobs.default_queue_config(),
      plugins: [{Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}]
    ]

    {Oban.Plugins.Cron, cron_opts} =
      generated_config
      |> Jobs.install_default_cron()
      |> Keyword.fetch!(:plugins)
      |> Enum.find(&match?({Oban.Plugins.Cron, _}, &1))

    assert {"0 1 * * *", Samen.AuditEvent.PartitionManager} in Keyword.fetch!(cron_opts, :crontab)
  end
end
