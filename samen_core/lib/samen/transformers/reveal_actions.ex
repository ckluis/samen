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
  @examined_key :samen_reveal_probes_examined

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
        probe_check(dsl_state, reveal_names)

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

  # A declared reveal action must be of the positive shape `Samen.Reveal.ProbeGuard` states
  # (the shared probe, `[:subject_id]`, an `actor_present()` gate and nothing else authorizing): fail the build otherwise, and persist what was examined so a host's test can prove
  # the rule saw its reveal action (never vacuous).
  defp probe_check(dsl_state, reveal_names) do
    actions = Transformer.get_entities(dsl_state, [:actions])
    policies = Transformer.get_entities(dsl_state, [:policies])

    case Samen.Reveal.ProbeGuard.violations(reveal_names, actions, policies) do
      [] ->
        {:ok,
         dsl_state
         |> Transformer.persist(@persist_key, MapSet.new(reveal_names))
         |> Transformer.persist(@examined_key, Enum.sort(reveal_names))}

      [{action, _} | _] = all ->
        {:error,
         Spark.Error.DslError.exception(
           module: Transformer.get_persisted(dsl_state, :module),
           path: [:pii, :reveal, action],
           message:
             "reveal action violates the probe rule: " <>
               Enum.map_join(all, "; ", fn {name, why} -> "#{inspect(name)} #{why}" end)
         )}
    end
  end

  @doc false
  @spec examined_key() :: atom()
  def examined_key, do: @examined_key

  @doc false
  @spec persist_key() :: atom()
  def persist_key, do: @persist_key
end
