defmodule Samen.Transformers.RevealActions do
  @moduledoc """
  Persists the set of **reveal actions** declared via `reveal :action` in a
  resource's `pii do … end` block, and fail-closes if any names a non-existent
  action (T1.5 clause (c); Gate-0 fix task #6).

  ## Why persist

  The reveal marker must be readable by the C3 `pii_reads` verifier (T1.8b) and
  the `Samen.Reveal` runtime as **real introspection** — not by re-parsing the DSL
  or by matching a `reveal` name prefix. We persist a `MapSet` of reveal action
  names under `:samen_pii_reveal_actions` so `Samen.Pii.Info.reveal_actions/1`
  reads it back through Spark's normal persisted-state surface.

  ## Fail-closed on unknown action

  A Spark *verifier* `DslError` does not reliably abort compile in this Ash/Spark
  version (T1.1 / T1.3 documented the same for the abbrev registry and vault
  routing). So the existence check is enforced HERE, in a transformer returning
  `{:error, DslError}`, which DOES hard-fail the build. `RevealActionExists`
  remains as a defense-in-depth verifier + introspection.

  ## Ordering

  Runs AFTER Ash's own action transformers so `defaults([...])`-expanded actions
  are materialized in DSL state and visible to the existence check. We only order
  after the Ash resource-transformer namespace; we do not depend on any other
  Samen transformer.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @persist_key :samen_pii_reveal_actions

  @impl true
  # Run late: after Ash has expanded `defaults` and built the action entities.
  def after?(module) do
    case Atom.to_string(module) do
      "Elixir.Ash.Resource.Transformers." <> _ -> true
      _ -> false
    end
  end

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    reveal_names =
      dsl_state
      |> Transformer.get_entities([:pii])
      |> Enum.filter(&match?(%Samen.Pii.RevealAction{}, &1))
      |> Enum.map(& &1.name)

    action_names =
      dsl_state
      |> Transformer.get_entities([:actions])
      |> Enum.map(& &1.name)
      |> MapSet.new()

    case Enum.reject(reveal_names, &MapSet.member?(action_names, &1)) do
      [] ->
        {:ok, Transformer.persist(dsl_state, @persist_key, MapSet.new(reveal_names))}

      [missing | _] = all_missing ->
        module = Transformer.get_persisted(dsl_state, :module)

        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:pii, :reveal, missing],
           message:
             "reveal #{inspect(missing)} names an action that does not exist on this " <>
               "resource. A `reveal :action` marker must point at a declared action " <>
               "(the action that returns vault plaintext for a granted actor). " <>
               "Missing: #{inspect(all_missing)}. Declared actions: " <>
               "#{inspect(MapSet.to_list(action_names))}."
         )}
    end
  end

  @doc false
  @spec persist_key() :: atom()
  def persist_key, do: @persist_key
end
