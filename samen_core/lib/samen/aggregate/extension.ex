defmodule Samen.Aggregate.Extension do
  @moduledoc """
  Spark DSL extension that MARKS a resource as belonging to the token-blind
  aggregate plane and wires the compile-time `NoPiiColumns` verifier (C7; T4.2
  clause (b)).

  A resource declared with `use Samen.Aggregate.Resource` carries this extension.
  Two things follow:

    1. **Marker** — it persists `aggregate_plane: true` (readable via
       `Samen.Aggregate.Info.aggregate_plane?/1`), so the whole-app mix-task
       backstop (`mix samen.verify.no_pii_columns`) and the aggregate domain can
       tell aggregate resources from tenant/operator resources.

    2. **Enforcement** — the "no pii_ columns at all" rule runs at COMPILE time on
       this resource ONLY (it is in THIS extension's lists, never the base
       `Samen.Extension`'s), so it can never false-positive on a tenant-plane
       resource — only a resource that opted INTO the aggregate plane is held to the
       rule. It fails compile if the resource declares a `pii_attribute`, a vault, a
       `pii_`-shaped column, or a relationship reaching a PII-bearing resource. Two
       modules share ONE rule set (`Samen.Verifiers.NoPiiColumns.violations/2`):

         * `Samen.Aggregate.NoPiiTransformer` — the HARD ABORT. Returns
           `{:error, DslError}`, which reliably aborts `Code.compile_string` in this
           Ash/Spark version (a verifier raise does not — it is defense-in-depth,
           per the T1.3 note). This is what makes the compile-time guarantee
           fail-closed.
         * `Samen.Verifiers.NoPiiColumns` — the named C7 verifier: introspection +
           the per-resource diagnostic + the shared rule source the whole-app
           `mix samen.verify.no_pii_columns` backstop reuses.

  This extension carries no DSL sections of its own — the marker is a persisted key
  set by `Samen.Aggregate.MarkTransformer`; the transformer/verifier read the
  resource's attributes/relationships/`pii do` block directly.
  """
  use Spark.Dsl.Extension,
    transformers: [Samen.Aggregate.MarkTransformer, Samen.Aggregate.NoPiiTransformer],
    verifiers: [Samen.Verifiers.NoPiiColumns]
end

defmodule Samen.Aggregate.Info do
  @moduledoc """
  Introspection surface for the aggregate-plane marker (T4.2).

  `aggregate_plane?/1` answers whether a resource opted into the token-blind
  aggregate plane (`use Samen.Aggregate.Resource`). The mix-task backstop and the
  aggregate domain read this.
  """

  @persist_key :samen_aggregate_plane

  @doc false
  def persist_key, do: @persist_key

  @doc """
  Is this resource an aggregate-plane resource (declared with
  `use Samen.Aggregate.Resource`)?
  """
  @spec aggregate_plane?(Spark.Dsl.t() | module()) :: boolean()
  def aggregate_plane?(resource) do
    Spark.Dsl.Extension.get_persisted(resource, @persist_key, false) == true
  rescue
    _ -> false
  end
end
