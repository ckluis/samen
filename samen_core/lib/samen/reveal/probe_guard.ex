defmodule Samen.Reveal.ProbeGuard do
  @moduledoc """
  The compile-time rule for a declared reveal action (`reveal :reveal_x` in a resource's `pii do … end`), enforced by
  `Samen.Transformers.RevealActions` on every resource of every host and generated app.

  A reveal action answers "does the actor holding this call hold a live grant on that subject". It must therefore

    * take NO argument that names an identity (`actor_id`, `user_id`, `requestor_id`, …): the grant is checked for the
      actor that RUNS the action (`Samen.Reveal.GrantProbe`), never for an id the caller supplies, and
    * NOT be `authorize_if(always())` (or `bypass … authorize_if(always())`): no actor at all must not get an answer.

  A violation fails the build (a `DslError` from a transformer; a verifier's does not reliably abort compile).
  `violations/3` is pure over the action and policy entities, so the rule is unit-testable on its own.
  """

  @identity ~r/(^|_)(actor|user|requestor|requester|operator|principal|member|account|person)(_id|_ids)?$/

  @doc "True when an argument name names an identity (`:actor_id`, `:user`, `:requestor_id`, …)."
  @spec identity_argument?(atom()) :: boolean()
  def identity_argument?(name) when is_atom(name), do: Regex.match?(@identity, Atom.to_string(name))

  @doc """
  The violations of `reveal_names` among `actions` (action entities) given `policies` (policy entities): a list of
  `{action_name, reason_string}`. Empty when every declared reveal action is clean.
  """
  @spec violations([atom()], [struct()], [struct()]) :: [{atom(), String.t()}]
  def violations(reveal_names, actions, policies) do
    by_name = Map.new(actions, &{&1.name, &1})

    Enum.flat_map(reveal_names, fn name ->
      case Map.fetch(by_name, name) do
        {:ok, action} -> argument_violations(name, action) ++ policy_violations(name, policies)
        :error -> []
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

  defp policy_violations(name, policies) do
    for %{policies: checks} = policy <- policies,
        names_action?(policy, name),
        Enum.any?(checks, &always_authorize?/1) do
      {name,
       "is `authorize_if(always())`: any caller, with any actor or none, can ask about anyone's grants " <>
         "(use `authorize_if(actor_present())`)"}
    end
  end

  # A policy names the action when its condition is `action(name)` (alone or in a list) or `action_type(:action)`.
  defp names_action?(%{condition: condition}, name) do
    condition
    |> List.wrap()
    |> Enum.any?(fn
      {Ash.Policy.Check.Action, opts} -> name in List.wrap(opts[:action])
      {Ash.Policy.Check.ActionType, opts} -> :action in List.wrap(opts[:type])
      _ -> false
    end)
  end

  defp always_authorize?(%{type: :authorize_if, check: {Ash.Policy.Check.Static, opts}}), do: opts[:result] == true
  defp always_authorize?(_), do: false
end
