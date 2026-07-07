defmodule Samen.Verifiers.TntBoundary do
  @moduledoc """
  Compile-time Spark verifier enforcing the **Tier-2 one-way boundary** (plan T3.9;
  vision doc §core "System = provable; tenant = validated-at-write, contained,
  one-way boundary").

  ## The boundary

  The tenant regime (Tier-2 custom objects, `Samen.CustomObjects.Record` /
  `tnt_record`) may reference OUT to the system regime — a `tnt_record.refs` entry
  holding a system row's id as a validated opaque ID. The system regime must NEVER
  reference IN to the tenant regime: a system resource cannot declare a
  relationship (`belongs_to`/`has_one`/`has_many`/`many_to_many`) whose destination
  is `tnt_record`.

  Why: a system→tenant relationship would create a referential edge from the
  compile-time-provable, catalogued, vault-governed system schema INTO the
  runtime-validated, contained tenant regime — inverting the source of truth
  exactly the way the vision doc rejects Twenty's runtime-DDL metadata model. It
  would also let a system read *reach into* uncatalogued tenant data, and (via
  `belongs_to`) put a real FK from a system table into `tnt_record`, breaking the
  structural no-FK guarantee.

  ## What this checks

  Runs on every `use Samen.Resource` resource (it is in the base extension's
  verifier list). For any resource that is NOT `Samen.CustomObjects.Record` itself,
  it fails the build if the resource declares a relationship whose `destination` is
  `Samen.CustomObjects.Record`. This is the T3.9 red path "a system resource
  declaring a relationship to `tnt_record` fails".

  The reverse direction is allowed and intentional: `Samen.CustomObjects.Record`
  holds OUT-references to system rows (as opaque IDs in `tnr_refs`, not as Ash
  relationships / FKs — validated by `Samen.CustomObjects.RecordChange`).

  A whole-app sweep is also available as `mix samen.verify.tnt_boundary` (the CI
  backstop, mirroring the other verifiers), which catches the same violation across
  all configured domains at once.
  """
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @tenant_record Samen.CustomObjects.Record

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    # The tenant record itself is exempt (it is the tenant regime; it holds OUT-refs
    # as data, not relationships).
    if module == @tenant_record do
      :ok
    else
      offending =
        dsl_state
        |> Verifier.get_entities([:relationships])
        |> Enum.filter(fn rel -> Map.get(rel, :destination) == @tenant_record end)

      case offending do
        [] ->
          :ok

        [rel | _] ->
          {:error,
           Spark.Error.DslError.exception(
             module: module,
             path: [:relationships, Map.get(rel, :name)],
             message:
               "system resource #{inspect(module)} declares relationship " <>
                 "#{inspect(Map.get(rel, :name))} → #{inspect(@tenant_record)} (tnt_record). " <>
                 "The Tier-2 one-way boundary forbids the system regime from " <>
                 "referencing INTO the tenant regime (plan T3.9). The tenant regime " <>
                 "references OUT to system rows as validated opaque IDs " <>
                 "(tnt_record.refs), never the reverse. Remove the relationship."
           )}
      end
    end
  end
end
