defmodule Samen.Verifiers.AbbrevRegistry do
  @moduledoc """
  Compile-time Spark verifier enforcing the committed abbrev registry
  (`Samen.AbbrevRegistry`).

  Runs after all transformers, so `:samen_abbrev` has been persisted. For the
  resource's abbrev it asserts, against `priv/abbrev_registry.json`:

    * the abbrev is **3-letter lowercase**;
    * the abbrev is **registered to this exact resource** (not another — that would
      be a collision or a recycle);
    * the abbrev is **present** in the registry (unreserved abbrevs fail).

  Any violation raises `Spark.Error.DslError` and fails the build fail-closed. This
  is how "abbrevs are permanent, collision-checked, never recycled" is enforced:
  two resources claiming the same abbrev, or an abbrev changed for an existing
  resource, cannot compile.

  The registry is deliberately re-read fresh at compile time (not cached in a
  module attribute) so editing `abbrev_registry.json` invalidates dependent
  resources correctly under `mix compile`.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)
    abbrev = Verifier.get_persisted(dsl_state, :samen_abbrev)

    registry = Samen.AbbrevRegistry.load()

    case Samen.AbbrevRegistry.validate(registry, to_string(abbrev), inspect(module)) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:samen, :abbrev],
           message: reason
         )}
    end
  end
end
