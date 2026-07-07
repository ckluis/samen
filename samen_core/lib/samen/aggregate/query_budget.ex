defmodule Samen.Aggregate.QueryLedgerRow do
  @moduledoc """
  One row per aggregate READ, accounted against **the cohort being queried** (and
  per-tenant in aggregate) — NOT the requesting actor (T4.5 clause (c)).

  Abbrev-prefixed (`aqb_*`) per the self-qualifying-storage idiom. Plain Ecto schema
  (kernel infra, mirroring the reveal-grant / suspension / impersonation ledgers).

  The **cohort_key** is the load-bearing granularity: the doc names per-actor accounting
  as the WRONG unit against collusion (two coordinating accounts each spend a fresh
  budget and recombine the answers), so the ledger is keyed by cohort + resource, never
  by actor. `tenant_scope` is `"__aggregate__"` for the cross-tenant plane (there is no
  single tenant — the aggregate spans all), recorded so a future per-tenant budget can
  aggregate here.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :aqb_id}
  schema "aqb_query_ledger" do
    field(:resource, :string, source: :aqb_resource)
    # The cohort this read touched (e.g. "tier=Pro", "status=open"), the accounting unit.
    field(:cohort_key, :string, source: :aqb_cohort_key)
    # "__aggregate__" for the cross-tenant plane; a future per-tenant budget scopes here.
    field(:tenant_scope, :string, source: :aqb_tenant_scope)
    # How many rows/cells this read returned for the cohort (a bounded count).
    field(:cell_count, :integer, source: :aqb_cell_count)
    # NON-load-bearing: recorded for forensics only, NEVER the accounting unit. The doc
    # is explicit that per-actor is the wrong granularity; we store the actor id purely
    # so a collusion pattern is *auditable after the fact*, and the budget check ignores it.
    field(:actor_id, :string, source: :aqb_actor_id)
    field(:read_at, :utc_datetime_usec, source: :aqb_read_at)
    field(:inserted_at, :utc_datetime_usec, source: :aqb_inserted_at)
  end
end

defmodule Samen.Aggregate.QueryBudget do
  @moduledoc """
  The **query-budget SCAFFOLD** — a ledger accounting every aggregate read against the
  **cohort being queried** (and per-tenant in aggregate), NOT the requesting actor
  (T4.5 clause (c); doc "Token-blind isn't inference-blind" honest edge).

  ## Posture: SCAFFOLD, not enforcement (stated exactly as the doc does)

  The doc is precise about what is enforced today vs. under construction:

  > We enforce the minimum-cohort / minimum-distinct floor today and treat the
  > cross-query budget / DP layer as posture under construction, not a solved proof —
  > and we name per-actor accounting as the wrong unit rather than implying it would hold.

  So this module:

    * **DOES**: record every aggregate read in a ledger, keyed by cohort (+ resource,
      + a `"__aggregate__"` tenant scope for the cross-tenant plane). Compute per-cohort
      read counts over a rolling window. **WARN** (log + telemetry) when a cohort's read
      count crosses a configurable threshold. This is a real, running ledger — the
      accounting the honest mitigation is built on.

    * **DOES NOT**: enforce (no read is DENIED by the budget today), implement
      cross-query suppression, differential-privacy noise, or t-closeness. Those are the
      **posture-under-construction** research track (plan T6.6). A repeated / overlapping
      / differencing query is recorded here and — today — still returns (subject to the
      k-anon / l-diversity FLOORS, which ARE enforced by `Samen.Aggregate.Privacy`). The
      full cross-query defence is deferred. This is stated in the T4.5 report with a
      differencing test that documents exactly what happens today.

  ## Why per-cohort, not per-actor (the wrong-unit claim, made real)

  > The unit matters here: a per-actor budget does not compose against collusion — two
  > coordinating accounts each spend a fresh budget and recombine the answers — so the
  > budget has to be tracked at the wrong-for-attacker granularity: global / per-cohort,
  > accounted against the cohort being queried (and per-tenant in aggregate), not per
  > requesting actor.

  The ledger key is `{resource, cohort_key, tenant_scope}` — the cohort being queried.
  Two colluding actors querying the SAME cohort accrue against the SAME ledger key: the
  count keeps climbing regardless of which actor read it. (The T4.5 collusion test proves
  this: two distinct actors reading the same cohort produce ONE growing per-cohort count,
  not two independent per-actor budgets.) The `actor_id` column exists for forensics only
  and is never the accounting unit — the `count/2` and `over_threshold?/2` predicates
  ignore it.

  ## Configuration

      config :samen_core, :query_budget_ledger_repo, MyApp.Repo   # falls back to reveal/impersonation repo
      config :samen_core, :query_budget_warn_threshold, 50        # reads-per-cohort before a WARN (default 50)
      config :samen_core, :query_budget_window_seconds, 3600      # rolling window for the count (default 1h)
      config :samen_core, :query_budget_enabled, true             # record reads (default true; recording only)

  There is deliberately NO `enforce` config — enforcement is the T6.6 track, not a flag
  we could flip and claim the defence. The warn threshold is the scaffold's teeth: it
  surfaces a differencing/collusion pattern for a human, without pretending to stop it.
  """

  alias Samen.Aggregate.QueryLedgerRow

  import Ecto.Query, only: [from: 2]
  require Logger

  @aggregate_scope "__aggregate__"
  @default_warn_threshold 50
  @default_window_seconds 3600

  @doc "The cross-tenant tenant scope sentinel (`\"__aggregate__\"`)."
  @spec aggregate_scope() :: String.t()
  def aggregate_scope, do: @aggregate_scope

  @doc "The Ecto repo backing the query ledger. Falls back to reveal/impersonation repo."
  @spec repo() :: module()
  def repo do
    Application.get_env(:samen_core, :query_budget_ledger_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      Application.get_env(:samen_core, :impersonation_repo) ||
      raise "Samen.Aggregate.QueryBudget needs a repo (:query_budget_ledger_repo)"
  end

  @doc "Is read-recording enabled? (default true — recording only, never enforcement)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:samen_core, :query_budget_enabled, true) != false
  end

  @doc "The per-cohort WARN threshold (reads within the window before a WARN fires)."
  @spec warn_threshold() :: pos_integer()
  def warn_threshold do
    case Application.get_env(:samen_core, :query_budget_warn_threshold, @default_warn_threshold) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_warn_threshold
    end
  end

  @doc "The rolling window (seconds) over which per-cohort reads are counted."
  @spec window_seconds() :: pos_integer()
  def window_seconds do
    case Application.get_env(:samen_core, :query_budget_window_seconds, @default_window_seconds) do
      n when is_integer(n) and n >= 1 -> n
      _ -> @default_window_seconds
    end
  end

  @doc """
  Record one aggregate read against a cohort. The **accounting** call — invoked by
  `Samen.Aggregate.read_all/2` for every cohort a read returned, BEFORE suppression is
  applied (we account what was *asked for*, not what survived the floor).

  `attrs`:
    * `:resource` (required) — the aggregate resource module (or its string name).
    * `:cohort_key` (required) — the cohort identifier string (e.g. `"tier=Pro"`).
    * `:cell_count` — rows/cells returned for the cohort (default 1).
    * `:actor_id` — forensics only, NEVER the accounting unit (default `"unknown"`).
    * `:tenant_scope` — defaults to `"__aggregate__"` (the cross-tenant plane).
    * `:repo`.

  Returns `{:ok, %{count: n, warned: bool}}` where `count` is the per-cohort read count
  in the window AFTER this read, and `warned` is whether a WARN fired. NEVER denies — this
  is a scaffold. If recording is disabled or the ledger is unreachable, returns
  `{:ok, %{count: 0, warned: false}}` (recording is best-effort; a failed ledger write
  must not break an aggregate read — the FLOORS, not the budget, are the enforced defence).
  """
  @spec record(map()) :: {:ok, %{count: non_neg_integer(), warned: boolean()}}
  def record(attrs) do
    if enabled?() do
      do_record(attrs)
    else
      {:ok, %{count: 0, warned: false}}
    end
  rescue
    # Best-effort recording: the ledger is a scaffold, not the load-bearing defence.
    # A ledger failure must never fail an aggregate read (that would make the SCAFFOLD
    # a fail-closed enforcement mechanism, which the doc says we deliberately do NOT
    # have yet). The FLOORS still ran; only the accounting is skipped.
    e ->
      Logger.warning("[query_budget] ledger record failed (recording skipped): #{inspect(e)}")
      {:ok, %{count: 0, warned: false}}
  end

  defp do_record(attrs) do
    r = Map.get(attrs, :repo, repo())
    resource = attrs |> Map.fetch!(:resource) |> to_name()
    cohort_key = Map.fetch!(attrs, :cohort_key)
    tenant_scope = Map.get(attrs, :tenant_scope, @aggregate_scope)
    cell_count = Map.get(attrs, :cell_count, 1)
    actor_id = Map.get(attrs, :actor_id, "unknown")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row =
      %QueryLedgerRow{}
      |> Ecto.Changeset.cast(
        %{
          resource: resource,
          cohort_key: cohort_key,
          tenant_scope: tenant_scope,
          cell_count: cell_count,
          actor_id: actor_id,
          read_at: now,
          inserted_at: now
        },
        [:resource, :cohort_key, :tenant_scope, :cell_count, :actor_id, :read_at, :inserted_at]
      )

    {:ok, _} = r.insert(row)

    count = count(%{resource: resource, cohort_key: cohort_key, tenant_scope: tenant_scope}, repo: r)
    threshold = warn_threshold()

    warned =
      if count >= threshold do
        # WARN, do not enforce. Telemetry + a log line surface the pattern for a human.
        :telemetry.execute(
          [:samen, :query_budget, :threshold_exceeded],
          %{count: count},
          %{resource: resource, cohort_key: cohort_key, tenant_scope: tenant_scope, threshold: threshold}
        )

        Logger.warning(
          "[query_budget] cohort read threshold crossed (WARN, not enforced): " <>
            "resource=#{resource} cohort=#{cohort_key} scope=#{tenant_scope} " <>
            "count=#{count} threshold=#{threshold} window=#{window_seconds()}s. " <>
            "Cross-query defence (budget enforcement + DP) is posture under construction (plan T6.6)."
        )

        true
      else
        false
      end

    {:ok, %{count: count, warned: warned}}
  end

  @doc """
  The per-cohort read count within the rolling window. The accounting unit is
  `{resource, cohort_key, tenant_scope}` — **actor is intentionally ignored** (per-actor
  is the wrong unit; two colluding actors on the same cohort accrue against this one count).

  `key`: `%{resource:, cohort_key:, tenant_scope:}` (resource/tenant_scope default sensibly).
  """
  @spec count(map(), keyword()) :: non_neg_integer()
  def count(key, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    resource = key |> Map.fetch!(:resource) |> to_name()
    cohort_key = Map.fetch!(key, :cohort_key)
    tenant_scope = Map.get(key, :tenant_scope, @aggregate_scope)
    since = DateTime.utc_now() |> DateTime.add(-window_seconds(), :second)

    r.aggregate(
      from(l in QueryLedgerRow,
        where:
          l.resource == ^resource and l.cohort_key == ^cohort_key and
            l.tenant_scope == ^tenant_scope and l.read_at >= ^since
      ),
      :count
    )
  end

  @doc """
  Would this cohort be over the WARN threshold? A predicate for a monitor/dashboard.
  Returns `false`-safe (never raises the caller): a ledger error is treated as "not over"
  because the budget does NOT gate reads — the floors do.
  """
  @spec over_threshold?(map(), keyword()) :: boolean()
  def over_threshold?(key, opts \\ []) do
    count(key, opts) >= warn_threshold()
  rescue
    _ -> false
  end

  defp to_name(mod) when is_atom(mod), do: inspect(mod)
  defp to_name(name) when is_binary(name), do: name
end
