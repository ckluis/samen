defmodule Samen.Transformers.NoPanColumns do
  @moduledoc """
  The **compile-time fail-closed enforcer** for the B5 no-PAN invariant
  (ADR-038 §3.5; T23) — the transformer twin of `Samen.Verifiers.NoPanColumns`.

  ## Why a transformer AND a verifier

  `Samen.Verifiers.NoPanColumns` (a Spark VERIFIER) computes the PAN-shape
  violations and is the named rule source for introspection and the whole-app
  `mix samen.verify.no_pan_columns` backstop. But in this Ash/Spark version a
  verifier's `{:error, _}` does NOT reliably ABORT `Code.compile_string` — the
  exact same quirk `Samen.Aggregate.NoPiiTransformer`'s moduledoc documents for
  its own verifier twin (`Samen.Verifiers.NoPiiColumns`). To make the compile-time
  guarantee ACTUALLY fail-closed — a resource declaring a PAN/CVC-shaped attribute
  does not compile, in any host, in any plane — the enforcement also runs as this
  TRANSFORMER, whose `{:error, Spark.Error.DslError}` return reliably aborts the
  build (the same mechanism `Samen.Transformers.MaterializePii` and
  `Samen.Aggregate.NoPiiTransformer` rely on).

  So: this transformer is the hard abort; `Samen.Verifiers.NoPanColumns` is the
  introspection + whole-app-sweep rule source. Both call
  `Samen.Verifiers.NoPanColumns.violations/2` — one rule, no drift.

  ## Ordering

  Runs AFTER `Samen.Transformers.AbbrevStorage` (consistent with the aggregate
  precedent) — the PAN-shape rule reads `attr.name` (the logical name), not the
  storage-prefixed `attr.source`, so ordering relative to abbrev-prefixing is not
  load-bearing here, but running last keeps every attribute the resource will ever
  declare fully materialized before the check runs.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(Samen.Transformers.AbbrevStorage), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)

    case Samen.Verifiers.NoPanColumns.violations(dsl_state, module) do
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
