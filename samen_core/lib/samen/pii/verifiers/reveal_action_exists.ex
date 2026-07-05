defmodule Samen.Pii.Verifiers.RevealActionExists do
  @moduledoc """
  Defense-in-depth verifier for the `reveal :action` marker (T1.5 clause (c)).

  Every `reveal :action` declared in a resource's `pii do … end` block must name a
  real action on that resource. The `Samen.Transformers.RevealActions` transformer
  is the fail-closed enforcer (a transformer `DslError` reliably aborts compile);
  this verifier runs over the fully-folded DSL as a second line so a fragment that
  contributes a `reveal` marker is also covered, and so introspection tooling has a
  compile-time guarantee to lean on.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    reveal_names =
      dsl_state
      |> Verifier.get_entities([:pii])
      |> Enum.filter(&match?(%Samen.Pii.RevealAction{}, &1))
      |> Enum.map(& &1.name)

    action_names =
      dsl_state
      |> Verifier.get_entities([:actions])
      |> Enum.map(& &1.name)
      |> MapSet.new()

    case Enum.reject(reveal_names, &MapSet.member?(action_names, &1)) do
      [] ->
        :ok

      [missing | _] = all_missing ->
        module = Verifier.get_persisted(dsl_state, :module)

        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:pii, :reveal, missing],
           message:
             "reveal #{inspect(missing)} names an action that does not exist on this " <>
               "resource. Missing: #{inspect(all_missing)}. Declared actions: " <>
               "#{inspect(MapSet.to_list(action_names))}."
         )}
    end
  end
end
