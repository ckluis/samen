defmodule Samen.Billing.MovementClassifier do
  @moduledoc """
  The PURE subscription-movement classifier (WS-B / G7; ADR-017 §2).

  Given a subscription's `before` and `after` state — a `{status, mrr_cents}` pair
  each — this maps the transition to a bounded movement `kind` and the SIGNED MRR
  delta. It is a **pure function** with no side effects, no DB access, no clock: the
  same `(before, after)` always yields the same `%Movement{}`. That purity is what
  makes it exhaustively property-testable over the whole state-pair space (AC-G7-1)
  and what makes the reconciliation invariant R1 (AC-G7-4/5) load-bearing — the
  ledger is only trustworthy because this function is deterministic and total.

  ## The state model

  A subscription state is `%{status: atom, mrr_cents: non_neg_integer}`:

    * `status` — one of the `Billing.Subscription` status enum values
      (`:active | :inactive | :trialing | :past_due | :cancelled | :unpaid`).
    * `mrr_cents` — the monthly recurring revenue this subscription contributes AT
      that state (0 when the state is non-revenue). Computed by the caller from the
      subscription's plan → active monthly price (the change resolves it; the
      classifier never touches price rows).

  We collapse `status` into a single boolean — **is this state revenue-active?** —
  because a movement is fundamentally a change in *contributed MRR*, and every status
  either contributes revenue or does not:

    * revenue-active (contributes `mrr_cents`): `:active`, `:trialing`, `:past_due`
      — a `:trialing`/`:past_due` sub is still ON THE BOOK (its MRR is recognized;
      `:past_due` is a dunning state, not a churn — churn is `:cancelled`).
    * revenue-inactive (contributes 0): `:inactive`, `:cancelled`, `:unpaid`.

  `nil`/`before == nil` is the "did not exist yet" state (a CREATE) — treated as
  revenue-inactive with 0 MRR.

  ## The classification table (every legal pair)

  Let `a? = active?(before)`, `b? = active?(after)`, `Δ = mrr_after - mrr_before`:

  | before active? | after active? | Δ            | kind            | delta |
  |----------------|---------------|--------------|-----------------|-------|
  | false          | true          | —            | `:new` / `:reactivation` | `+mrr_after` |
  | true           | false         | —            | `:churn`        | `-mrr_before` |
  | true           | true          | Δ > 0        | `:expansion`    | `+Δ` |
  | true           | true          | Δ < 0        | `:contraction`  | `Δ` (negative) |
  | true           | true          | Δ = 0        | `:noop`         | `0` |
  | false          | false         | —            | `:noop`         | `0` |

  **`:new` vs `:reactivation`** — both are inactive→active, both a `+mrr_after`
  delta. The classifier distinguishes them by the `prior_active?` flag the caller
  threads: a subscription that has NEVER been revenue-active before is `:new`; one
  that was active, churned, and is now active again is `:reactivation`. When the
  caller cannot supply `prior_active?` (e.g. a bare `classify/2`), an
  inactive→active transition defaults to `:new` (the day-one/backfill case — a
  reactivation requires a prior-active fact the caller must assert).

  ## Illegal pairs are REFUSED (fail-closed totality)

  `classify/2` accepts only well-formed states: `status` in the enum and
  `mrr_cents` a non-negative integer. A malformed state (unknown status, negative
  or non-integer MRR, missing key) is REFUSED via `classify!/2` raising, or returned
  as `{:error, reason}` from `classify/2`. There is no silent "default" bucket for a
  state outside the model — the space is closed by construction.

  ## No PII by construction

  Inputs are enums + integers; the output `%Movement{}` is `kind` (atom) + integers.
  Nothing here can carry a name, email, or freeform string.
  """

  @statuses [:active, :inactive, :trialing, :past_due, :cancelled, :unpaid]

  # Revenue-active statuses: the subscription is ON THE BOOK, its mrr_cents counts.
  @active_statuses [:active, :trialing, :past_due]

  # Revenue-inactive statuses: contributes 0 MRR.
  @inactive_statuses [:inactive, :cancelled, :unpaid]

  @kinds [:new, :expansion, :contraction, :churn, :reactivation, :noop]

  defmodule Movement do
    @moduledoc """
    The pure classification result: a bounded movement `kind` + the signed MRR delta
    + the before/after MRR that rides onto the `mov` ledger row (so the ledger is
    self-contained and reconciles without a price re-join — ADR-017 §2).
    """
    @enforce_keys [:kind, :delta_cents, :before_cents, :after_cents]
    defstruct [:kind, :delta_cents, :before_cents, :after_cents]

    @type t :: %__MODULE__{
            kind: :new | :expansion | :contraction | :churn | :reactivation | :noop,
            delta_cents: integer(),
            before_cents: non_neg_integer(),
            after_cents: non_neg_integer()
          }
  end

  @doc "The subscription status enum this classifier models."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "The revenue-active statuses (on the book — mrr_cents counts)."
  @spec active_statuses() :: [atom()]
  def active_statuses, do: @active_statuses

  @doc "The revenue-inactive statuses (off the book — contributes 0 MRR)."
  @spec inactive_statuses() :: [atom()]
  def inactive_statuses, do: @inactive_statuses

  @doc "The movement kinds this classifier can emit."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  Is a subscription state revenue-active (on the book)?

  `nil` (the pre-existence / CREATE-from-nothing state) is inactive.
  """
  @spec active?(nil | map()) :: boolean()
  def active?(nil), do: false
  def active?(%{status: status}), do: status in @active_statuses
  def active?(_), do: false

  @doc """
  Classify a `(before, after)` state pair → `{:ok, %Movement{}}` | `{:error, reason}`.

  `before` may be `nil` (a CREATE — the subscription did not exist). `after` must be
  a well-formed state. Options:

    * `:prior_active?` — `true` if this subscription was EVER revenue-active before
      this transition (threaded by the caller from history). Distinguishes
      `:reactivation` (was active before) from `:new` (never). Defaults to `false`
      (→ inactive→active classifies as `:new`).

  Illegal states (unknown status, negative/non-integer MRR) return `{:error, _}` —
  never a silent bucket.
  """
  @spec classify(nil | map(), map(), keyword()) ::
          {:ok, Movement.t()} | {:error, atom()}
  def classify(before, after_state, opts \\ []) do
    with {:ok, before_norm} <- normalize(before, :before),
         {:ok, after_norm} <- normalize(after_state, :after) do
      prior_active? = Keyword.get(opts, :prior_active?, false)
      {:ok, do_classify(before_norm, after_norm, prior_active?)}
    end
  end

  @doc """
  Bang form: classify or RAISE on an illegal state pair (fail-closed totality — the
  state space is closed; a state outside the model is a bug, not a `:noop`).
  """
  @spec classify!(nil | map(), map(), keyword()) :: Movement.t()
  def classify!(before, after_state, opts \\ []) do
    case classify(before, after_state, opts) do
      {:ok, movement} ->
        movement

      {:error, reason} ->
        raise ArgumentError,
              "MovementClassifier: illegal state pair (#{reason}); " <>
                "before=#{inspect(before)} after=#{inspect(after_state)}"
    end
  end

  # --- the pure decision table (over normalized {active?, mrr_cents} states) ---

  # before is the normalized map or the :nonexistent sentinel; after is normalized.
  defp do_classify(before_norm, after_norm, prior_active?) do
    a? = state_active?(before_norm)
    b? = state_active?(after_norm)

    # The CONTRIBUTED MRR each state carries onto the ledger row: the raw mrr_cents
    # when the state is revenue-active, else 0 (an inactive state contributes
    # nothing). This makes the row self-consistent: `delta == after_cents -
    # before_cents` ALWAYS holds, so the waterfall reconciles from the row alone.
    before_cents = if a?, do: state_mrr(before_norm), else: 0
    after_cents = if b?, do: state_mrr(after_norm), else: 0

    {kind, delta} = decide(a?, b?, before_cents, after_cents, prior_active?)

    %Movement{
      kind: kind,
      delta_cents: delta,
      before_cents: before_cents,
      after_cents: after_cents
    }
  end

  # inactive → active : a new sale or a reactivation (delta = +after MRR).
  defp decide(false, true, _before, after_cents, prior_active?) do
    kind = if prior_active?, do: :reactivation, else: :new
    {kind, after_cents}
  end

  # active → inactive : churn (delta = -before MRR, i.e. the whole contribution lost).
  defp decide(true, false, before_cents, _after, _prior) do
    {:churn, -before_cents}
  end

  # active → active : expansion / contraction / noop by the signed delta.
  defp decide(true, true, before_cents, after_cents, _prior) do
    delta = after_cents - before_cents

    cond do
      delta > 0 -> {:expansion, delta}
      delta < 0 -> {:contraction, delta}
      true -> {:noop, 0}
    end
  end

  # inactive → inactive : no movement.
  defp decide(false, false, _before, _after, _prior) do
    {:noop, 0}
  end

  # --- normalization: closes the state space, fail-closed on illegal input ---

  # A CREATE's before is nil → the :nonexistent sentinel (inactive, 0 MRR).
  defp normalize(nil, :before), do: {:ok, :nonexistent}

  # after must never be nil (a subscription always has a state after a write).
  defp normalize(nil, :after), do: {:error, :after_state_nil}

  defp normalize(%{status: status} = state, _which) do
    mrr = Map.get(state, :mrr_cents, 0)

    cond do
      status not in @statuses ->
        {:error, :unknown_status}

      not (is_integer(mrr) and mrr >= 0) ->
        {:error, :illegal_mrr_cents}

      true ->
        {:ok, %{status: status, mrr_cents: mrr}}
    end
  end

  defp normalize(_other, _which), do: {:error, :malformed_state}

  defp state_active?(:nonexistent), do: false
  defp state_active?(%{status: status}), do: status in @active_statuses

  defp state_mrr(:nonexistent), do: 0
  defp state_mrr(%{mrr_cents: mrr}), do: mrr
end
