defmodule Samen.Jobs do
  @moduledoc """
  The Oban conventions layer for Samen (T2.1).

  ## Queue taxonomy

  Every Samen product registers these named queues. Per-queue concurrency caps
  enforce blast-radius isolation (vision doc §limits "separate queues with
  per-queue concurrency limits so a runaway worker class can't starve the others
  or the OLTP path").

      queue name       | default concurrency | purpose
      -----------------+--------------------+----------------------------------------
      default          |        10          | general-purpose; catch-all
      rollups          |         2          | AshOban rollup/matview refresh (T2.3)
      webhooks_out     |         5          | outbound webhook delivery (T3.13)
      erasure          |         1          | crypto-shred orchestration (T1.7/T2.9)
      maintenance      |         1          | partition detach, vacuum, pruning (T2.2)
      reveal           |         5          | reveal-grant auto-revoke (T1.6 D6)

  Configure via your application config (see `default_queue_config/0`):

      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: Samen.Jobs.default_queue_config()

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

  Wire `Oban.Plugins.Cron` in your Oban config:

      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: Samen.Jobs.default_queue_config(),
        plugins: [
          {Oban.Plugins.Cron, crontab: Samen.Jobs.default_crontab()},
          {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
        ]

  In tests, set `plugins: false` or `testing: :manual` to disable.

  ## Starvation isolation

  Each queue runs its own pool of Oban workers governed by its `:limit`.
  A queue saturated with slow jobs cannot starve other queues: Oban's SKIP LOCKED
  selects only from a single queue's rows per worker cycle, and each queue's workers
  are bounded to their `:limit`. Verified by `starvation_isolation_test.exs`.
  """

  @doc """
  The canonical Samen queue configuration.

  Intended to be pasted into your Oban config or merged with product-specific
  additions. The limits are defaults; tune them per deployment.

      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: Samen.Jobs.default_queue_config()

  Returns a keyword list of `[queue_name: concurrency_limit]`.
  """
  @spec default_queue_config() :: keyword(pos_integer())
  def default_queue_config do
    [
      default: 10,
      rollups: 2,
      webhooks_out: 5,
      erasure: 1,
      maintenance: 1,
      reveal: 5
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
  """
  @spec default_crontab() :: [{String.t(), module()}]
  def default_crontab do
    [
      {"*/10 * * * *", Samen.Jobs.RollupRefreshWorker},
      {"*/5 * * * *", Samen.Anchor.SealWorker},
      {"*/15 * * * *", Samen.AuditChain.VerifyWorker},
      {"*/10 * * * *", Samen.BreakGlass.ReconcileWorker},
      {"0 3 * * *", Samen.Retention.SweepWorker}
    ]
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
