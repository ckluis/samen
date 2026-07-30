defmodule Samen.Automation.ActionStep do
  @moduledoc """
  One Reactor step = one automation action (ADR-039 §5.1). Resolves the bounded
  `kind` to its `Samen.Automation.Action` module and invokes `run/2`. A returned
  `{:error, kind}` becomes a Reactor step error → whole-run compensation (undo of
  completed steps in reverse) → the run finalizes `:failed`. An action **failure
  never crashes the engine** — it is a value, not a raise. Even a raising action is
  caught by Reactor and turned into a step error.
  """
  use Reactor.Step

  alias Samen.Automation.Action

  @impl true
  def run(arguments, _context, _options) do
    action = arguments[:action] || %{}
    ctx = arguments[:ctx]
    index = arguments[:index] || 0
    kind = action["kind"] || action[:kind]

    case Action.module_for(to_string(kind)) do
      nil ->
        {:error, %{index: index, kind: kind, status: :failed, error_kind: :unknown_action_kind}}

      module ->
        try do
          case module.run(config(action), ctx) do
            {:ok, meta} ->
              {:ok, %{index: index, kind: kind, status: :succeeded, meta: bounded(meta)}}

            {:error, error_kind} ->
              {:error, %{index: index, kind: kind, status: :failed, error_kind: error_kind}}
          end
        rescue
          e ->
            {:error,
             %{index: index, kind: kind, status: :failed, error_kind: :raised,
               detail: Exception.message(e)}}
        end
    end
  end

  @impl true
  def undo(value, arguments, _context, _options) do
    action = arguments[:action] || %{}
    ctx = arguments[:ctx]
    kind = action["kind"] || action[:kind]
    meta = Map.get(value || %{}, :meta, %{})

    case Action.module_for(to_string(kind)) do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :undo, 3) do
          _ = module.undo(config(action), meta, ctx)
          :ok
        else
          :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # The action's own config keys, minus the routing key.
  defp config(action) do
    action
    |> Map.drop(["kind", :kind, "index", :index])
  end

  # Run outcome meta must stay bounded (ids/enums only — ADR-039 §5.1). Drop any
  # freeform/detail keys before they could land in a Run outcome (T42).
  defp bounded(meta) when is_map(meta), do: Map.drop(meta, [:detail, "detail"])
  defp bounded(_), do: %{}
end

defmodule Samen.Automation.Compile do
  @moduledoc """
  Workflow → runtime `Reactor` (ADR-039 §3.3, §5; ADR-037 §5.7 Reactor ADOPT). The
  execution layer is a runtime-built reactor — no hand-built DAG executor. Each action
  config becomes one `Samen.Automation.ActionStep`, chained sequentially (step *i*
  depends on step *i-1*'s result), so ordering + reverse-order compensation are the
  reactor's job. T39 ships this with the single `notify` action; T40 adds the other
  seven — the compile path never changes, they just register more `kind`s.

  `run/2` returns `{:ok, outcomes}` where `outcomes` is the ordered per-action outcome
  list (bounded — `%{index, kind, status, duration_ms, ...}`), or `{:error, reason}`
  when an action failed (completed steps are compensated first; `reason` is whatever
  shape Reactor's own step-error propagation produces — callers must not assume a
  fixed shape, see `Samen.Automation.RunWorker`'s defensive extraction).

  `Samen.Automation.Recorder` (ADR-039 §8.1) is attached as a Reactor middleware on
  every built reactor — it stamps each action step's `duration_ms` onto its outcome
  without any action module knowing a log exists (T42).
  """

  alias Reactor.Argument
  alias Samen.Automation.{Condition, Context}

  @doc """
  Build + run the reactor for a workflow's actions against a fire-time context.

  `actions` is the raw jsonb action list (validated at write time); `ctx` is a
  `Samen.Automation.Context`. An empty action list succeeds vacuously.
  """
  @spec run([map()] | nil, Context.t()) ::
          {:ok, [map()]} | {:error, term()}
  def run(actions, %Context{} = ctx) do
    actions = normalize(actions)

    if actions == [] do
      {:ok, []}
    else
      case build(actions, ctx) do
        {:ok, reactor} ->
          case Reactor.run(reactor, %{}, %{}, async?: false) do
            {:ok, outcomes} -> {:ok, List.wrap(outcomes)}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Raw jsonb → a list of action maps that at least carry a bounded string kind.
  defp normalize(nil), do: []

  defp normalize(actions) when is_list(actions) do
    actions
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn a ->
      kind = a["kind"] || a[:kind]
      Map.put(a, "kind", to_string(kind))
    end)
    |> Enum.reject(fn a -> a["kind"] in [nil, ""] end)
  end

  defp normalize(_), do: []

  defp build(actions, ctx) do
    reactor =
      case Reactor.Builder.add_middleware(Reactor.Builder.new(), Samen.Automation.Recorder) do
        {:ok, r} -> r
        {:error, _reason} -> Reactor.Builder.new()
      end

    result =
      actions
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, reactor, nil}, fn {action, i}, {:ok, r, prev} ->
        name = :"action_#{i}"

        args = [
          Argument.from_value(:action, Map.put(action, "index", i)),
          Argument.from_value(:index, i),
          Argument.from_value(:ctx, ctx)
        ]

        args = if prev, do: [Argument.from_result(:_prev, prev) | args], else: args

        case Reactor.Builder.add_step(r, name, Samen.Automation.ActionStep, args, async?: false) do
          {:ok, r} -> {:cont, {:ok, r, name}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, r, last} <- result,
         {:ok, r} <- collect_return(r, actions, last) do
      {:ok, r}
    end
  end

  # Return the ordered outcome list. We add a terminal aggregation step that depends
  # on every action step so the reactor's return is the full outcome list in order.
  defp collect_return(reactor, actions, _last) do
    names = for {_a, i} <- Enum.with_index(actions), do: :"action_#{i}"

    args = for n <- names, do: Argument.from_result(n, n)

    with {:ok, reactor} <-
           Reactor.Builder.add_step(reactor, :_outcomes, Samen.Automation.CollectStep, args,
             async?: false
           ),
         {:ok, reactor} <- Reactor.Builder.return(reactor, :_outcomes) do
      {:ok, reactor}
    end
  end

  # Unused helper kept for symmetry with the Condition gate (callers pre-gate).
  @doc false
  def valid_conditions?(conditions), do: Condition.valid?(conditions)
end

defmodule Samen.Automation.CollectStep do
  @moduledoc """
  Terminal Reactor step that aggregates the per-action outcomes into the ordered
  list the run records (ADR-039 §5.1 outcome shape). Every action step feeds in as a
  named argument (`action_0`, `action_1`, …); this step sorts them by index.
  """
  use Reactor.Step

  @impl true
  def run(arguments, _context, _options) do
    outcomes =
      arguments
      |> Enum.filter(fn {k, _v} ->
        k |> Atom.to_string() |> String.starts_with?("action_")
      end)
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.sort_by(& &1[:index])

    {:ok, outcomes}
  end
end
