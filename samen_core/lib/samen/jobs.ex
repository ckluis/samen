defmodule Samen.Jobs do
  @moduledoc """
  The Oban conventions layer for Samen (T2.1).

  ## Queue taxonomy

  Every Samen product registers these named queues. Per-queue concurrency caps
  enforce blast-radius isolation (vision doc §limits "separate queues with
  per-queue concurrency limits so a runaway worker class can't starve the others
  or the OLTP path").

      queue name         | default concurrency | purpose
      -------------------+--------------------+--------------------------------------
      default            |        10          | general-purpose; catch-all
      rollups            |         2          | AshOban rollup/matview refresh (T2.3)
      webhooks_out       |         5          | outbound webhook delivery (T3.13)
      webhooks_in        |         5          | inbound webhook processing (B9; ADR-038 §5.2)
      erasure            |         1          | crypto-shred orchestration (T1.7/T2.9)
      maintenance        |         1          | partition detach, vacuum, pruning (T2.2)
      audit_verify       |         1          | audit-chain integrity sweep (F3.5; O3)
      reveal             |         5          | reveal-grant auto-revoke (T1.6 D6)
      automation         |         3          | E1 workflow dispatch/run (ADR-039 §4.1)
      automation_timers  |         2          | E4/E5/outreach timer fan-out (ADR-039 §6.3/§7.3)

  `default_queue_config/0` is the SINGLE SOURCE OF TRUTH for that taxonomy, and it
  is not advisory: a job enqueued to a queue no producer is configured for sits in
  `oban_jobs` with `state = 'available'` FOREVER — no error, no retry, no discard,
  an empty DLQ, and a healthy-looking Oban. That silent no-drain (B-OBAN) is why
  hosts must NOT hand-maintain their own queue list.

  ## Adoption seam — hosts derive, never hand-list

  `config/config.exs` is evaluated BEFORE dependency modules are loaded, so a host
  config cannot call `default_queue_config/0` there. The queue set is therefore
  installed at `application.ex` start time, exactly like the cron schedule:

      {Oban, Samen.Jobs.install_defaults(Application.fetch_env!(:samen_core, Oban))}

  `install_defaults/1` = `install_default_queues/1` (this taxonomy) +
  `install_default_cron/1` (`default_crontab/0`). A host config declares only its
  `repo:` (plus any plugins and deliberate per-queue LIMIT overrides); every
  canonical queue is filled in for it. `Samen.Jobs.QueueParity` + `mix
  samen.verify.oban_queues` gate the invariant that every queue any shipped
  `Oban.Worker` (including AshOban-generated trigger workers/schedulers) enqueues
  to is present in that resolved configuration.

  ## Same-transaction enqueue

  `enqueue_in_tx/3` is the canonical way to enqueue a job inside an existing
  `Ecto.Multi`. It generalises the pattern T1.6 established for the reveal-grant
  auto-revoke job: the job row is inserted inside the same DB transaction as the
  domain row(s), so a rollback of the multi leaves NO `oban_jobs` row.

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:order, order_changeset)
      |> Samen.Jobs.enqueue_in_tx(:notify, OrderNotifyWorker.new(%{order_id: id}))
      |> repo.transaction()

  ## DLQ / retry policy convention

  Workers should `use Oban.Worker` with these options:

      use Oban.Worker,
        queue: :default,              # one of the taxonomy queues above
        max_attempts: 20,             # capped; 20 covers ~6 hours of backoff
        unique: [period: 60]          # tune per-worker for idempotency

  Oban's built-in exponential backoff is `backoff_pow * 2^(attempt - 1)` seconds
  (default base ≈ 15 s), so 20 attempts spans ~4–6 hours before discard. After
  `max_attempts` exhausted, Oban automatically moves the job to `:discarded` state
  — this is the dead-letter bucket. Monitor `oban_jobs WHERE state = 'discarded'`.

  The `:discard_on` option can be used to short-circuit exhaustion for
  known-permanent errors (e.g. `{:discard, reason}` from `perform/1`).

  ## Cron / periodic jobs

  The canonical schedule rides the same `install_defaults/1` seam as the queues, so
  a host config declares only what is host-specific:

      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [{Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}]

  In tests, set `plugins: false` or `testing: :manual` to disable. A host that
  declares its OWN `Oban.Plugins.Cron` wins outright (no double-scheduling) — which
  also means it REPLACES `default_crontab/0` wholesale, including the audit-partition
  roll-forward. Add your entries to a host cron block only if you also restate the
  canonical ones (`Samen.Jobs.default_crontab() ++ mine`).

  ## Starvation isolation

  Each queue runs its own pool of Oban workers governed by its `:limit`.
  A queue saturated with slow jobs cannot starve other queues: Oban's SKIP LOCKED
  selects only from a single queue's rows per worker cycle, and each queue's workers
  are bounded to their `:limit`. Verified by `starvation_isolation_test.exs`.
  """

  @doc """
  The canonical Samen queue configuration — the single source of truth.

  Every queue that any SHIPPED worker or AshOban trigger enqueues to MUST appear
  here, because a queue that is enqueued-to but not configured never drains and
  never errors (B-OBAN). `Samen.Jobs.QueueParity.check/1` (and the
  `mix samen.verify.oban_queues` gate) enforce exactly that containment by
  DISCOVERING the enqueued-to queues from the compiled `Oban.Worker` modules —
  so adding a worker on a new queue without registering it here fails the gate.

  Hosts do not paste this list. They start Oban through the framework seam and
  the taxonomy is installed for them (see `install_defaults/1`):

      {Oban, Samen.Jobs.install_defaults(Application.fetch_env!(:samen_core, Oban))}

  The limits are defaults; tune them per deployment by declaring the queue with a
  different limit in the host's Oban config (host limits WIN; host omissions are
  filled in — a host can retune a queue, it cannot silently drop one).

  Returns a keyword list of `[queue_name: concurrency_limit]`.
  """
  @spec default_queue_config() :: keyword(pos_integer())
  def default_queue_config do
    [
      default: 10,
      rollups: 2,
      webhooks_out: 5,
      webhooks_in: 5,
      erasure: 1,
      maintenance: 1,
      # F3.5 / O3 — the audit-chain integrity VERIFY sweep runs on its OWN queue, NOT
      # `:maintenance`, so a long (keyset-bounded) verify cannot starve the audit-partition
      # roll-forward (`Samen.AuditEvent.PartitionManager`) that shares the `:maintenance`
      # concurrency-1 lane and whose absence fails `aud_event` writes at the month boundary.
      audit_verify: 1,
      reveal: 5,
      # ADR-039 §4.1/§6.3/§7.3 (T39/T41/T118) — the E1 workflow dispatch/run queue
      # and the E4/E5 + outreach TIMER fan-out queue (a different load shape than
      # rule dispatch, so its own queue per the blueprint's own moduledoc). These
      # back `Samen.Automation.{DispatchWorker,RunWorker}`, `Samen.Sequences.SendWorker`
      # and the approvals-escalation / reminder / sequence-step AshOban triggers.
      # Canonical (not driftwood-only) since B-OBAN: any host mounting the Automation,
      # Outreach or Approvals scopes enqueues here, and an unconfigured queue is a
      # permanent silent stall rather than an error.
      automation: 3,
      automation_timers: 2
    ]
  end

  @doc """
  The canonical Samen cron schedule. Add product-specific entries alongside.

  Returns a list of `{cron_expression, worker_module}` tuples for
  `Oban.Plugins.Cron`.

  Built-in entries:

    - `"*/10 * * * *"` → `Samen.Jobs.RollupRefreshWorker` (rollup heartbeat;
      T2.3 will replace with real AshOban triggers)
    - `"*/5 * * * *"` → `Samen.Anchor.SealWorker` (T4.3 WORM-anchor seal cron; seals
      every org's audit-chain head into the write-once store. The cadence bounds the
      wholesale-rewrite detection window — ADR-002 §3.3.)
    - `"*/15 * * * *"` → `Samen.AuditChain.VerifyWorker` (F3.5 integrity sweep;
      re-verifies every org's live hash chain and emits `[:samen, :audit_chain, :verify]`
      / `[:samen, :audit_chain, :tamper]` telemetry — continuous tamper detection, not
      only at the next external anchor comparison).
    - `"*/10 * * * *"` → `Samen.BreakGlass.ReconcileWorker` (F3.5 break-glass
      reconciliation; anchors operator-node-local deferred break-glass entries back into
      the central chain and emits `[:samen, :break_glass, :unanchored]` — closes the
      honest-residue window on a cadence instead of only by a manual call).
    - `"0 3 * * *"` → `Samen.Retention.SweepWorker` (F3.2 per-scope retention; nightly
      shreds/prunes host-registered data classes past their configured TTL. No-op until a
      host sets `:samen_core, :retention_specs`.)
    - `"0 1 * * *"` → `Samen.AuditEvent.PartitionManager` (T128 audit-partition roll-forward;
      daily at 01:00 ensures the current + next N monthly `aud_event` partitions exist
      before rows arrive. WITHOUT this cron, production audit writes FAIL once the wall
      clock crosses the latest migration-seeded partition boundary — a silent audit-trail
      write-failure / data-loss on a compliance surface. The job is idempotent
      (`CREATE TABLE IF NOT EXISTS`), bounded (fixed `months_ahead` lookahead, default 2 →
      3 partitions/run), and DATA-SAFE — it never drops/detaches a partition or rewrites
      existing data. The daily cadence with a 2-month lookahead means even a long run of
      missed executions cannot open a partition gap. `aud_event` is the only partitioned
      table, so this single entry covers the whole partition surface.)
    - `"*/30 * * * *"` → `Samen.AI.Embeddings.ReembedWorker` (T186 incremental re-embed sweep;
      re-embeds ONLY `aie_embedding` rows whose stamped model has drifted from the currently
      configured embedder — never a full-table re-embed. A no-op / self-discarding job on a
      host with no embedder wired (ADR-014 fail-honest: nothing to re-embed against).)
  """
  @spec default_crontab() :: [{String.t(), module()}]
  def default_crontab do
    [
      {"*/10 * * * *", Samen.Jobs.RollupRefreshWorker},
      {"*/5 * * * *", Samen.Anchor.SealWorker},
      {"*/15 * * * *", Samen.AuditChain.VerifyWorker},
      {"*/10 * * * *", Samen.BreakGlass.ReconcileWorker},
      {"0 3 * * *", Samen.Retention.SweepWorker},
      {"0 1 * * *", Samen.AuditEvent.PartitionManager},
      {"*/30 * * * *", Samen.AI.Embeddings.ReembedWorker}
    ]
  end

  @doc """
  Install the canonical Samen cron plugin (`default_crontab/0`) into an Oban
  child-spec option list, unless cron is disabled or the host already wired its own.

  This is the framework-first adoption seam for periodic jobs: a generated app's
  `application.ex` starts Oban with

      {Oban, Samen.Jobs.install_default_cron(Application.fetch_env!(:samen_core, Oban))}

  so EVERY generated app inherits the canonical schedule — including the
  `Samen.AuditEvent.PartitionManager` audit-partition roll-forward (T128) — with no
  host action. `default_crontab/0` is the single source of truth; nothing re-lists the
  entries per app.

  Why not in `config.exs`: product config is evaluated before framework modules are
  loaded, so `default_crontab/0` cannot be called there. `application.ex` `start/2`
  runs after code loading, which is why the plugin is assembled here.

  Rules (order-independent, idempotent):

    * `plugins: false` (the test-env convention: `testing: :manual, plugins: false`) —
      returned unchanged, so tests never schedule cron.
    * a host that already declared an `Oban.Plugins.Cron` plugin — returned unchanged,
      so an explicit host schedule always wins (no double-scheduling).
    * otherwise — prepend `{Oban.Plugins.Cron, crontab: default_crontab()}`, preserving
      any existing plugins (e.g. the `Oban.Plugins.Pruner`).
  """
  @spec install_default_cron(keyword()) :: keyword()
  def install_default_cron(oban_opts) when is_list(oban_opts) do
    case Keyword.fetch(oban_opts, :plugins) do
      {:ok, false} ->
        oban_opts

      {:ok, plugins} when is_list(plugins) ->
        if cron_plugin?(plugins) do
          oban_opts
        else
          Keyword.put(oban_opts, :plugins, [default_cron_plugin() | plugins])
        end

      _ ->
        Keyword.put(oban_opts, :plugins, [default_cron_plugin()])
    end
  end

  defp default_cron_plugin, do: {Oban.Plugins.Cron, crontab: default_crontab()}

  defp cron_plugin?(plugins) do
    Enum.any?(plugins, fn
      Oban.Plugins.Cron -> true
      {Oban.Plugins.Cron, _opts} -> true
      _ -> false
    end)
  end

  @doc """
  Install the canonical Samen queue taxonomy (`default_queue_config/0`) into an
  Oban child-spec option list.

  The queue counterpart of `install_default_cron/1`, and the fix for B-OBAN: before
  this seam existed every host hand-listed its own `queues:` and the four shipped
  lists had DRIFTED away from the taxonomy — `:webhooks_in` was configured by none
  of them (so every inbound billing/email provider webhook job sat `available`
  forever while the ingress returned 200), and `:automation`/`:automation_timers`
  by one.
  A missing queue produces no error anywhere: `Oban.insert` succeeds, no producer
  ever claims the row, the DLQ stays empty, and the operator DLQ-replay button
  re-enqueues into the same dead queue and reports success.

  Rules (order-independent, idempotent):

    * `queues: false` (the `samen_web` test convention, and Oban's own "this node
      runs no producers" switch) — returned UNCHANGED. Declining to run queues on
      a node is a deliberate topology choice; silently dropping one is not.
    * a host-declared list — MERGED with the canonical taxonomy: a queue the host
      declared keeps the HOST's limit (retuning is legitimate), and every canonical
      queue the host omitted is added at its default limit (omission is the bug).
    * no `:queues` key — the full canonical taxonomy is installed.

  ## Examples

      # A host that declares no queues gets the whole taxonomy.
      install_default_queues(repo: MyApp.Repo)[:queues][:webhooks_in]
      #=> 5

      # A host that retunes one queue keeps its limit AND still gets the rest.
      install_default_queues(queues: [maintenance: 4])[:queues][:maintenance]
      #=> 4
      install_default_queues(queues: [maintenance: 4])[:queues][:webhooks_in]
      #=> 5
  """
  @spec install_default_queues(keyword()) :: keyword()
  def install_default_queues(oban_opts) when is_list(oban_opts) do
    case Keyword.fetch(oban_opts, :queues) do
      {:ok, false} ->
        oban_opts

      {:ok, host_queues} when is_list(host_queues) ->
        Keyword.put(oban_opts, :queues, merge_queues(host_queues))

      _ ->
        Keyword.put(oban_opts, :queues, default_queue_config())
    end
  end

  # Host-declared limits win; every canonical queue the host omitted is appended.
  defp merge_queues(host_queues) do
    missing =
      Enum.reject(default_queue_config(), fn {name, _limit} ->
        Keyword.has_key?(host_queues, name)
      end)

    host_queues ++ missing
  end

  @doc """
  The single Oban adoption seam: canonical queues + canonical cron.

  Equivalent to `install_default_queues/1` followed by `install_default_cron/1`.
  This is what every shipped host and every generated app passes to the `{Oban, _}`
  child spec, so ONE call makes a host inherit the whole taxonomy:

      {Oban, Samen.Jobs.install_defaults(Application.fetch_env!(:samen_core, Oban))}

  Both halves are idempotent and both respect an explicit host opt-out
  (`queues: false` / `plugins: false`, the test convention).
  """
  @spec install_defaults(keyword()) :: keyword()
  def install_defaults(oban_opts) when is_list(oban_opts) do
    oban_opts
    |> install_default_queues()
    |> install_default_cron()
  end

  @doc """
  Enqueue a job inside an existing `Ecto.Multi`, using the same transaction.

  This is the canonical Samen same-transaction enqueue helper. It generalises
  the pattern established by T1.6 (reveal-grant auto-revoke): the job row is
  inserted inside the same DB transaction as the domain row(s), so a rollback
  leaves NO `oban_jobs` row.

  ## Arguments

    - `multi` — an existing `Ecto.Multi`
    - `name` — the multi step name (atom)
    - `changeset_or_job` — an `Oban.Job` changeset (from `MyWorker.new/2`) OR
      an `Oban.Job` struct

  ## Options

    - `:on_conflict` — passed to `Oban.insert/2`; defaults to `:nothing`

  ## Example

      Ecto.Multi.new()
      |> Ecto.Multi.insert(:record, Record.changeset(attrs))
      |> Samen.Jobs.enqueue_in_tx(:notify, MyWorker.new(%{record_id: id}))
      |> Repo.transaction()

  The crash test in `jobs_enqueue_in_tx_test.exs` proves that a multi that rolls
  back AFTER the `enqueue_in_tx` step leaves no `oban_jobs` row.
  """
  @spec enqueue_in_tx(Ecto.Multi.t(), atom(), Oban.Job.t() | Ecto.Changeset.t()) ::
          Ecto.Multi.t()
  def enqueue_in_tx(%Ecto.Multi{} = multi, name, changeset_or_job, opts \\ []) do
    on_conflict = Keyword.get(opts, :on_conflict, :nothing)
    Oban.insert(multi, name, changeset_or_job, on_conflict: on_conflict)
  end

  @doc """
  Build a DLQ-policy-compliant `use Oban.Worker` worker module spec.

  This is a documentation helper — it returns the canonical options map that
  should be passed to `use Oban.Worker`. It does NOT define the module itself.

  ## Returns

  A keyword list suitable for `use Oban.Worker, <opts>`:

      %{queue: queue, max_attempts: 20, unique: [period: 60]}

  Workers that need different backoff ceilings can override `max_attempts` but
  MUST NOT exceed 30 (≈ 1 day of backoff) without a documented reason. Workers
  that discard on permanent failures should return `{:discard, reason}` from
  `perform/1`.
  """
  @spec worker_defaults(atom()) :: keyword()
  def worker_defaults(queue \\ :default) when is_atom(queue) do
    [
      queue: queue,
      max_attempts: 20,
      unique: [period: 60]
    ]
  end
end
