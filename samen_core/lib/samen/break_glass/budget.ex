defmodule Samen.BreakGlass.RevealLedgerRow do
  @moduledoc """
  One row per (operator, subject) reveal within a window — the durable ledger the
  **breadth budget** counts (T4.4 clause (d)). Abbrev-prefixed (`brl_*`).

  A row is written on EVERY successful reveal path (routine reveal, break-glass) so
  the budget is a cross-path count — a break-glass reveal spends the same budget as a
  routine one; an operator cannot evade the budget by routing through the emergency
  path. `brl_break_glass` records which path spent it (for the audit trail), but the
  DISTINCT-subject count that trips the budget is path-agnostic.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :brl_id}
  schema "brl_reveal_ledger" do
    field(:operator_id, :string, source: :brl_operator_id)
    field(:subject_id, :string, source: :brl_subject_id)
    field(:break_glass, :boolean, source: :brl_break_glass, default: false)
    field(:revealed_at, :utc_datetime_usec, source: :brl_revealed_at)
  end
end

defmodule Samen.BreakGlass.Budget do
  @moduledoc """
  The per-operator **breadth budget** (T4.4 clause (d); doc "honest edges"
  break-glass bullet). N DISTINCT subjects revealed per rolling window; exceeding it
  **auto-suspends** the operator (`Samen.OperatorPlane.Suspension`), which makes
  every subsequent reveal path deny — INCLUDING break-glass.

  ## Why breadth, not depth

  The threat the budget targets is a compromised or rogue operator credential
  quietly sweeping many subjects (a mass-reveal), not one operator revealing one
  subject repeatedly (that is the reveal-grant model's job, and each reveal is
  already audited). So the budget counts DISTINCT `subject_id`s in the window, not
  total reveals — a "breadth" budget, matching the doc's wording.

  ## The count is durable and cross-path

  Reveals are recorded in `brl_reveal_ledger`. `record_and_check/1`:

    1. inserts a ledger row (idempotently for a repeat of the same subject in the
       window — a repeat does not widen breadth);
    2. counts DISTINCT subjects for the operator within the window;
    3. if the distinct count > the budget, auto-suspends the operator and returns
       `{:suspended, count}` — the CALLER must then deny the reveal that tripped it
       AND all subsequent ones (the suspension makes that automatic).

  The count is computed AFTER the insert, so the reveal that crosses the threshold
  is itself denied (the operator does not get a "free" Nth+1 reveal before the
  suspension bites).

  ## Configuration

      # Distinct subjects per window before auto-suspend (default 25).
      config :samen_core, :break_glass_breadth_budget, 25
      # The rolling window in seconds (default 3600 = 1h).
      config :samen_core, :break_glass_breadth_window_seconds, 3600
      config :samen_core, :operator_suspension_repo, MyApp.Repo  # ledger rides this repo
  """

  alias Samen.BreakGlass.RevealLedgerRow
  alias Samen.OperatorPlane.Suspension

  import Ecto.Query, only: [from: 2]

  @default_budget 25
  @default_window_seconds 3600

  @doc "The breadth budget (distinct subjects per window). Configurable."
  @spec budget() :: pos_integer()
  def budget do
    Application.get_env(:samen_core, :break_glass_breadth_budget, @default_budget)
  end

  @doc "The rolling window in seconds. Configurable."
  @spec window_seconds() :: pos_integer()
  def window_seconds do
    Application.get_env(:samen_core, :break_glass_breadth_window_seconds, @default_window_seconds)
  end

  @doc "The repo backing the ledger (rides the suspension repo)."
  @spec repo() :: module()
  def repo, do: Suspension.repo()

  @doc """
  Record a reveal by `operator_id` of `subject_id` and check the breadth budget.

  `attrs`: `:operator_id`, `:subject_id` (required), `:break_glass` (bool, default
  false), `:org_id` (chain partition for the suspend event), `:repo`, `:now`.

  Returns:
    * `{:ok, distinct_count}` — within budget; the reveal may proceed;
    * `{:suspended, distinct_count}` — the reveal that tripped the budget: the
      operator was auto-suspended and THIS reveal (plus all subsequent) must deny.
  """
  @spec record_and_check(map()) :: {:ok, non_neg_integer()} | {:suspended, non_neg_integer()}
  def record_and_check(attrs) do
    r = Map.get(attrs, :repo, repo())
    operator_id = fetch!(attrs, :operator_id)
    subject_id = fetch!(attrs, :subject_id)
    now = Map.get(attrs, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    # 1. Record this reveal (idempotent-ish: a repeat subject in-window does not
    #    widen breadth; we still write a row, but DISTINCT collapses repeats).
    insert_ledger(r, operator_id, subject_id, Map.get(attrs, :break_glass, false), now)

    # 2. Count DISTINCT subjects for this operator in the window.
    count = distinct_subject_count(r, operator_id, now)

    # 3. Trip the budget → auto-suspend + deny.
    if count > budget() do
      {:ok, _} =
        Suspension.suspend(%{
          operator_id: operator_id,
          reason:
            "breadth budget exceeded: #{count} distinct subjects in #{window_seconds()}s window " <>
              "(budget #{budget()})",
          org_id: Map.get(attrs, :org_id) || Samen.AuditChain.global_org(),
          repo: r
        })

      {:suspended, count}
    else
      {:ok, count}
    end
  end

  @doc """
  Distinct subjects revealed by an operator within the current window (read-only;
  does NOT record). For dashboards / the runbook's "how close to the budget" view.
  """
  @spec current_breadth(String.t(), keyword()) :: non_neg_integer()
  def current_breadth(operator_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    distinct_subject_count(r, operator_id, now)
  end

  # ==========================================================================
  # Internal
  # ==========================================================================

  defp insert_ledger(r, operator_id, subject_id, break_glass, now) do
    r.insert!(
      %RevealLedgerRow{}
      |> Ecto.Changeset.cast(
        %{
          operator_id: operator_id,
          subject_id: subject_id,
          break_glass: break_glass,
          revealed_at: now
        },
        [:operator_id, :subject_id, :break_glass, :revealed_at]
      )
    )
  end

  defp distinct_subject_count(r, operator_id, now) do
    window_start = DateTime.add(now, -window_seconds(), :second)

    r.one(
      from(l in RevealLedgerRow,
        where: l.operator_id == ^operator_id and l.revealed_at >= ^window_start,
        select: count(l.subject_id, :distinct)
      )
    ) || 0
  end

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end
end
