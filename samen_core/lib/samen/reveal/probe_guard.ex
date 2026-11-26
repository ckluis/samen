defmodule Samen.Reveal.ProbeGuard do
  @moduledoc """
  The compile-time rule for a declared reveal action (`reveal :reveal_x` in a resource's `pii do … end`), enforced by
  `Samen.Transformers.RevealActions` on every resource of every host and generated app.

  A reveal action answers "does the actor holding this call hold a live grant on that subject". The rule is POSITIVE:
  the declaration must be of exactly this shape, and anything else fails the build.

    * `run({Samen.Reveal.GrantProbe, _})` is the action's implementation, and its arguments are exactly `[:subject_id]`
      (nothing names an identity or a principal: the grant is checked for the actor that RUNS the action, never for a
      value the caller supplies), and
    * the policies that can apply to the action (a `policy`, a `bypass`, or one inside a `policy_group`, whatever its
      condition: a condition that is not provably about another action is taken to apply) contain one
      `policy action(:name)` whose only check is `authorize_if(actor_present())`, no other `authorize_if` /
      `authorize_unless` (an `always()`, an `expr(true)`, a custom check), and no `bypass` except one whose only check is
      `authorize_if` an allow-listed named check module (`@allowed_bypass_checks`: AshOban's own interaction, which runs the
      trigger with no actor, where the probe itself still answers a missing actor `{:error, :denied}`).

  A violation fails the build (a `DslError` from a transformer; a verifier's does not reliably abort compile).
  `violations/3` is pure over the action and policy entities, so the rule is unit-testable on its own.
  """

  @identity ~r/(^|_)(actor|user|requestor|requester|operator|principal|member|account|person)(_id|_ids)?$/

  @doc "True when an argument name names an identity (`:actor_id`, `:user`, `:requestor_id`, …)."
  @spec identity_argument?(atom()) :: boolean()
  def identity_argument?(name) when is_atom(name), do: Regex.match?(@identity, Atom.to_string(name))

  @allowed_bypass_checks [AshOban.Checks.AshObanInteraction]
  @actor_present Ash.Policy.Check.ActorPresent
  @authorizing [:authorize_if, :authorize_unless]

  @doc """
  The violations of `reveal_names` among `actions` (action entities) given `policies` (policy entities): a list of
  `{action_name, reason_string}`. Empty when every declared reveal action is clean.
  """
  @spec violations([atom()], [struct()], [struct()]) :: [{atom(), String.t()}]
  def violations(reveal_names, actions, policies) do
    by_name = Map.new(actions, &{&1.name, &1})
    flat = flatten(policies)

    Enum.flat_map(reveal_names, fn name ->
      case Map.fetch(by_name, name) do
        {:ok, action} ->
          identity = argument_violations(name, action)
          identity ++ shape_violations(name, action, identity != []) ++ policy_violations(name, flat)

        :error ->
          []
      end
    end)
  end

  defp argument_violations(name, action) do
    for %{name: arg} <- Map.get(action, :arguments, []), identity_argument?(arg) do
      {name,
       "takes the identity argument #{inspect(arg)}: the grant must be checked for the actor that RUNS the action " <>
         "(use `run({Samen.Reveal.GrantProbe, label: …})`), never for an id the caller names"}
    end
  end

  defp shape_violations(name, action, identity?) do
    run =
      case Map.get(action, :run) do
        {Samen.Reveal.GrantProbe, _} ->
          []

        other ->
          [{name, "does not `run({Samen.Reveal.GrantProbe, label: …})` (it runs #{inspect(other)}): the grant is checked only by the shared probe"}]
      end

    args = action |> Map.get(:arguments, []) |> Enum.map(& &1.name)

    args_v =
      if args == [:subject_id] or identity?,
        do: [],
        else: [{name, "takes the arguments #{inspect(args)}; a reveal action takes exactly `[:subject_id]`"}]

    run ++ args_v
  end

  # Every policy (a group's members with the group's condition prepended) that may apply to the action.
  defp policy_violations(name, flat) do
    applying = Enum.filter(flat, &applies?(&1, name))
    {bypasses, plain} = Enum.split_with(applying, &(Map.get(&1, :bypass?) == true))

    bypass_v =
      for b <- bypasses, not allowed_bypass?(b) do
        {name,
         "can be authorized by a `bypass` (condition #{inspect(b.condition)}) other than an allow-listed check " <>
           "(#{inspect(@allowed_bypass_checks)}): no actor must not get an answer"}
      end

    gate? = Enum.any?(plain, &gate?(&1, name))

    gate_v =
      if gate?,
        do: [],
        else: [{name, "has no `policy action(#{inspect(name)})` whose only check is `authorize_if(actor_present())`"}]

    other_v =
      for p <- plain,
          not gate?(p, name),
          %{type: type, check: check} <- p.policies,
          type in @authorizing,
          normalize(check) != {@actor_present, []} do
        {name, "#{type}(#{describe(check)}) applies to it: only `authorize_if(actor_present())` may" <> always_hint(check)}
      end

    bypass_v ++ gate_v ++ other_v
  end

  defp always_hint(check) do
    if normalize(check) == {Ash.Policy.Check.Static, [result: true]},
      do: " (it is `authorize_if(always())`: any caller, with any actor or none, can ask about anyone's grants)",
      else: ""
  end

  defp describe(check), do: inspect(check)

  defp allowed_bypass?(%{policies: checks}) do
    checks != [] and
      Enum.all?(checks, fn %{type: type, check: check} ->
        type == :authorize_if and elem(normalize(check), 0) in @allowed_bypass_checks
      end)
  end

  # The one required policy: named for this action, and its only check is `authorize_if(actor_present())`.
  defp gate?(%{policies: [%{type: :authorize_if, check: check}]} = policy, name) do
    named?(policy, name) and normalize(check) == {@actor_present, []}
  end

  defp gate?(_, _), do: false

  defp named?(%{condition: condition}, name) do
    condition |> List.wrap() |> Enum.any?(&match?({Ash.Policy.Check.Action, _}, normalize(&1)) and name in actions_of(&1))
  end

  defp actions_of(ref), do: ref |> normalize() |> elem(1) |> Keyword.get(:action) |> List.wrap()

  # May the policy apply to the action? Only a condition PROVABLY about something else says no; any other check
  # (`always()`, an expression, a custom module) is taken to hold.
  defp applies?(%{condition: condition}, name) do
    condition
    |> List.wrap()
    |> Enum.all?(fn ref ->
      case normalize(ref) do
        {Ash.Policy.Check.Action, opts} -> name in List.wrap(opts[:action])
        {Ash.Policy.Check.ActionType, opts} -> :action in List.wrap(opts[:type])
        {Ash.Policy.Check.Static, opts} -> opts[:result] != false
        _ -> true
      end
    end)
  end

  defp normalize(mod) when is_atom(mod), do: {mod, []}
  defp normalize({mod, opts}) when is_atom(mod), do: {mod, List.wrap(opts)}
  defp normalize(other), do: other

  defp flatten(policies), do: Enum.flat_map(policies, &flatten_one(&1, []))

  defp flatten_one(%Ash.Policy.PolicyGroup{condition: cond, policies: members}, outer) do
    Enum.flat_map(members, &flatten_one(&1, outer ++ List.wrap(cond)))
  end

  # field policies guard field reads, not actions
  defp flatten_one(%{fields: _}, _outer), do: []

  defp flatten_one(%{policies: _} = policy, outer),
    do: [Map.put(policy, :condition, outer ++ List.wrap(Map.get(policy, :condition)))]

  defp flatten_one(_, _), do: []
end
