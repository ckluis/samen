defmodule Samen.Aggregate.NoPiiTransformer do
  @moduledoc """
  The **compile-time fail-closed enforcer** for the token-blind aggregate plane's
  "no pii_ columns at all" invariant (C7; T4.2 clause (b)).

  ## Why a transformer AND a verifier

  `Samen.Verifiers.NoPiiColumns` (a Spark VERIFIER) computes the same violations and
  is the plan's named C7 verifier — it drives the per-resource diagnostic and the
  whole-app `mix samen.verify.no_pii_columns` backstop. But in this Ash/Spark
  version a verifier raise does NOT reliably ABORT `Code.compile_string` (it is
  defense-in-depth, exactly as the T1.3 PII DSL notes for its own verifier). To make
  the compile-time guarantee actually **fail closed** — a PII-reaching aggregate
  resource does not compile — the enforcement also runs as this TRANSFORMER, which
  returns `{:error, Spark.Error.DslError}` and reliably aborts the build (the same
  mechanism `Samen.Transformers.MaterializePii` relies on).

  So: the transformer is the hard abort; the verifier is the introspection + the
  whole-app sweep's shared rule source. Both call
  `Samen.Verifiers.NoPiiColumns.violations/2` — one rule set, no drift.

  ## Ordering

  Runs AFTER `Samen.Transformers.MaterializePii` so the `pii do` block's columns are
  materialized before the `pii_`-shaped-column check reads the resource's
  attributes.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(Samen.Transformers.MaterializePii), do: true
  def after?(Samen.Transformers.AbbrevStorage), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    case Samen.Verifiers.NoPiiColumns.violations(dsl_state, module) do
      [] ->
        {:ok, dsl_state}

      [{path, message} | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: path,
           message: message
         )}
    end
  end
end
