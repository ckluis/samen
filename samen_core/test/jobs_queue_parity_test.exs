defmodule Samen.Jobs.QueueParityTest do
  @moduledoc """
  B-OBAN: worker-queue ⊆ configured-queue PARITY, discovered — never re-listed.

  ## The bug this replaces a hand-written list with

  Three queues shipped enqueued-to but configured NOWHERE canonical:
  `:webhooks_in` (`Samen.Webhook.IngestWorker`, behind every inbound
  Stripe/Postmark/Resend/SES webhook) was in ZERO of four host configs, and
  `:automation`/`:automation_timers` (workflow dispatch/run, the sequence-step,
  reminder and escalation AshOban triggers) were in one. A job on an unconfigured
  queue does not fail: `Oban.insert` returns `{:ok, job}`, the row sits at
  `state = 'available'` forever, no producer claims it, the DLQ stays empty, and
  the ingress already answered 200.

  `jobs_queue_taxonomy_test.exs` could not catch that. It asserted a HARD-CODED
  "six canonical queues" list — which itself omitted `webhooks_in` — against
  `default_queue_config/0`. It compared one restatement of the taxonomy to
  another; no test compared the taxonomy to the WORKERS.

  ## What is proved here

    1. **Discovery is real and non-vacuous.** `Samen.Jobs.QueueParity.discover/1`
       reads `c:Oban.Worker.__opts__/0` off the COMPILED modules of samen_core and
       everything built on it. The floor assertions below fail if that returns
       nothing or collapses to a handful — which is what makes a green parity
       result mean something (the A2/X9 vacuous-pass lesson).
    2. **Both discovery paths are live** — a hand-written `use Oban.Worker` module
       AND an AshOban-GENERATED trigger worker (created by
       `AshOban.Transformers.DefineSchedulers`, which also emits `use Oban.Worker`).
       If a future AshOban version stopped generating real workers, discovery would
       silently lose every trigger queue; this pins it.
    3. **The parity invariant itself** — every discovered queue is in
       `default_queue_config/0`, and in the RESOLVED runtime config the framework
       seam produces. Specifically covers the three regression queues by name.
    4. **The seam cannot silently drop a queue** — `install_default_queues/1`
       backfills a host list that omits canonical queues, preserves a host's
       deliberate limit override, and honours an explicit `queues: false`.
    5. **`check/1` fails CLOSED on empty discovery** rather than reporting success.

  Sabotage twins (`scripts/sabotages/197-*`, `198-*`) drop `:webhooks_in` from the
  canonical taxonomy and neuter the seam's backfill; each must flip a NAMED test here.
  """
  use ExUnit.Case, async: true

  alias Samen.Jobs
  alias Samen.Jobs.QueueParity

  # The three queues whose absence WAS the blocker. Named explicitly so the
  # regression cannot come back quietly under a general assertion.
  @regression_queues [:webhooks_in, :automation, :automation_timers]

  # -----------------------------------------------------------------------
  # 1. Discovery is real (anti-vacuity floors)
  # -----------------------------------------------------------------------

  test "discovery finds a substantial, attributable worker population (NOT vacuous)" do
    sources = QueueParity.discover()
    workers = sources |> Map.values() |> List.flatten()

    refute sources == %{},
           "discovery returned NOTHING — a parity check that discovers nothing verifies " <>
             "nothing. Either the Oban.Worker introspection broke or the app tree is empty."

    # Floors, not an inventory: they must be low enough never to need touching when a
    # worker is added, and high enough that a broken discovery step cannot slip past.
    assert map_size(sources) >= 6,
           "expected >= 6 distinct enqueued-to queues, got #{map_size(sources)}: " <>
             inspect(Map.keys(sources))

    assert length(workers) >= 12,
           "expected >= 12 discovered worker modules, got #{length(workers)}"

    # Every discovered module really is an Oban.Worker with the queue it was filed under.
    for {queue, mods} <- sources, mod <- mods do
      assert function_exported?(mod, :__opts__, 0), "#{inspect(mod)} is not an Oban.Worker"
      assert to_string(mod.__opts__()[:queue]) == to_string(queue)
    end
  end

  test "discovery covers BOTH a hand-written worker and an AshOban-generated trigger worker" do
    sources = QueueParity.discover()
    workers = sources |> Map.values() |> List.flatten()

    # (a) hand-written: `use Oban.Worker, queue: :webhooks_in` — the ingress worker
    # that was the reachable silent path.
    assert Samen.Webhook.IngestWorker in Map.get(sources, :webhooks_in, []),
           "hand-written worker discovery is broken: Samen.Webhook.IngestWorker not found " <>
             "under :webhooks_in (found: #{inspect(Map.get(sources, :webhooks_in))})"

    # (b) AshOban-generated: the trigger worker/scheduler modules the DSL creates.
    # `SamenCore.Support.ApprovalsFixture.Approval` declares `trigger :expire_scan`
    # with explicit worker/scheduler module names on :automation_timers.
    generated = [
      SamenCore.Support.ApprovalsFixture.Approval.ExpireScanWorker,
      SamenCore.Support.ApprovalsFixture.Approval.ExpireScanScheduler
    ]

    for mod <- generated do
      assert mod in workers,
             "AshOban trigger-worker discovery is broken: #{inspect(mod)} not discovered. " <>
               "If AshOban stops emitting `use Oban.Worker`, EVERY trigger queue would " <>
               "silently vanish from this gate."

      assert mod in Map.get(sources, :automation_timers, [])
    end
  end

  # -----------------------------------------------------------------------
  # 2. The parity invariant
  # -----------------------------------------------------------------------

  test "every discovered worker queue is registered in default_queue_config/0" do
    sources = QueueParity.discover()
    configured = Keyword.keys(Jobs.default_queue_config())

    unregistered =
      sources
      |> Enum.reject(fn {queue, _mods} -> queue in configured end)
      |> Enum.sort_by(&elem(&1, 0))

    assert unregistered == [],
           "queues enqueued to but NOT in Samen.Jobs.default_queue_config/0 — jobs on " <>
             "them would sit `available` forever with no error:\n" <>
             Enum.map_join(unregistered, "\n", fn {q, mods} ->
               "  - #{inspect(q)} <- #{Enum.map_join(mods, ", ", &inspect/1)}"
             end)
  end

  test "the three B-OBAN regression queues are discovered AND canonically configured" do
    sources = QueueParity.discover()
    configured = Keyword.keys(Jobs.default_queue_config())

    for queue <- @regression_queues do
      assert Map.has_key?(sources, queue),
             "expected #{inspect(queue)} to be enqueued to by a shipped worker/trigger"

      assert queue in configured,
             "#{inspect(queue)} is enqueued to but missing from default_queue_config/0 — " <>
               "this is the exact B-OBAN silent no-drain regression"
    end
  end

  test "check/0 passes against the RESOLVED runtime Oban config and reports its evidence" do
    assert {:ok, report} = QueueParity.check()

    assert report.discovered != []
    assert :samen_core in report.apps

    # The resolved config is what application.ex actually starts: the host's
    # `config :samen_core, Oban` piped through the framework seam.
    {:ok, resolved} = QueueParity.configured_queues()
    assert report.configured == Enum.sort(resolved)

    for queue <- @regression_queues do
      assert queue in resolved,
             "resolved runtime config is missing #{inspect(queue)} — the seam did not install it"
    end
  end

  # -----------------------------------------------------------------------
  # 3. check/1 fails CLOSED, and detects a real drop
  # -----------------------------------------------------------------------

  test "check/1 FAILS on empty discovery instead of reporting a vacuous pass" do
    # An app population with no Oban workers at all. The containment predicate is
    # trivially true here; a fail-open verifier would print a green line.
    assert {:error, {:no_workers_discovered, [:stdlib]}} = QueueParity.check(apps: [:stdlib])
  end

  test "check/1 REPORTS a queue whose producer is missing, naming the workers (refutable)" do
    # POSITIVE CONTROL for the passing parity assertions above: the containment
    # predicate must actually be able to say NO. Fed the pre-fix taxonomy (the six
    # queues every host hand-listed, minus the three that were never configured),
    # it must name every gap and attribute each to its worker.
    legacy_six = [:default, :rollups, :webhooks_out, :erasure, :maintenance, :reveal]

    assert {:error, {:unconfigured_queues, missing, report}} =
             QueueParity.check(configured: legacy_six)

    missing_names = Enum.map(missing, &elem(&1, 0))

    for queue <- @regression_queues do
      assert queue in missing_names,
             "the pre-fix config omitted #{inspect(queue)} — check/1 must report it"
    end

    assert report.configured == Enum.sort(legacy_six)

    {_queue, mods} = Enum.find(missing, fn {q, _} -> q == :webhooks_in end)

    assert Samen.Webhook.IngestWorker in mods,
           "the report must attribute the dead queue to the worker that enqueues to it"
  end

  # -----------------------------------------------------------------------
  # 4. The framework seam — hosts derive, and cannot silently drop a queue
  # -----------------------------------------------------------------------

  test "install_default_queues/1 installs the full taxonomy when the host lists none" do
    installed = Jobs.install_default_queues(repo: SamenCore.TestRepo)
    assert Keyword.fetch!(installed, :queues) == Jobs.default_queue_config()
  end

  test "install_default_queues/1 BACKFILLS a host list that omits canonical queues" do
    # Exactly the four shipped host configs before this fix: six queues, no webhooks_in.
    legacy = [
      repo: SamenCore.TestRepo,
      queues: [default: 10, rollups: 2, webhooks_out: 5, erasure: 1, maintenance: 1, reveal: 5]
    ]

    queues = Jobs.install_default_queues(legacy) |> Keyword.fetch!(:queues)

    for {name, _limit} <- Jobs.default_queue_config() do
      assert Keyword.has_key?(queues, name),
             "canonical queue #{inspect(name)} was not backfilled into the host's list"
    end

    for queue <- @regression_queues do
      assert Keyword.fetch!(queues, queue) == Keyword.fetch!(Jobs.default_queue_config(), queue)
    end
  end

  test "install_default_queues/1 preserves a host's deliberate limit override" do
    tuned = Jobs.install_default_queues(queues: [maintenance: 4, automation: 9])
    queues = Keyword.fetch!(tuned, :queues)

    # Host limits win...
    assert Keyword.fetch!(queues, :maintenance) == 4
    assert Keyword.fetch!(queues, :automation) == 9
    # ...and the rest of the taxonomy still lands at its default.
    assert Keyword.fetch!(queues, :webhooks_in) == 5
    assert Keyword.fetch!(queues, :reveal) == 5
  end

  test "install_default_queues/1 honours an explicit `queues: false` (no-producer node)" do
    base = [repo: SamenCore.TestRepo, queues: false, plugins: false]
    assert Jobs.install_default_queues(base) == base
    assert {:ok, :disabled} = QueueParity.configured_queues(base)
    # ...and parity is moot on such a node, not a failure.
    assert {:ok, _} = QueueParity.check(oban_opts: base)
  end

  test "install_default_queues/1 is idempotent" do
    once = Jobs.install_default_queues(repo: SamenCore.TestRepo)
    assert Jobs.install_default_queues(once) == once
  end

  test "install_defaults/1 installs BOTH the taxonomy and the canonical cron" do
    installed =
      Jobs.install_defaults(
        repo: SamenCore.TestRepo,
        plugins: [{Oban.Plugins.Pruner, max_age: 60}]
      )

    assert Keyword.fetch!(installed, :queues) == Jobs.default_queue_config()

    {Oban.Plugins.Cron, cron_opts} =
      installed |> Keyword.fetch!(:plugins) |> Enum.find(&match?({Oban.Plugins.Cron, _}, &1))

    assert Keyword.fetch!(cron_opts, :crontab) == Jobs.default_crontab()
  end
end
