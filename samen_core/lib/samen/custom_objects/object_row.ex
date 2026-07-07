defmodule Samen.CustomObjects.ObjectRow do
  @moduledoc """
  Ecto schema for a `tnt_object` row — the **Tier-2 tenant custom-object catalog**
  (plan T3.9; vision doc §core "custom OBJECTS in `tnt_record` + `tnt_object`",
  malleability ladder rung 3 "custom objects"; Twenty's metadata model as the
  SPEC only — re-implemented in Ash, NOT its runtime-dynamic-DDL architecture).

  ## What `tnt_object` is — the third rung of the ladder

  Where `tnt_field` (T3.8) lets an org add custom *fields* to an existing system
  resource's jsonb bag, `tnt_object` lets an org define a whole custom *object* it
  invented — the vision doc's canonical example, a clinic's `VaccineLot`. An object
  definition is just: an org-scoped key + a label + an enabled flag. The object's
  *fields* reuse the Tier-1 `tnt_field` catalog (shared machinery, T3.8): a custom
  object's fields are `tnt_field` rows whose `tnt_table_name` is the object's
  synthetic table name (`Samen.CustomObjects.object_table/1`). The object's *rows*
  are `tnt_record` rows (`Samen.CustomObjects.Record`, an org-scoped Ash resource
  with a validated jsonb bag).

  ## Why a plain Ecto DDL table (not an Ash resource)

  Same bootstrap reasoning as `tam_table`/`fld_field`/`tnt_field`: `tnt_object`
  must exist before any `tnt_record` write can be validated against its definition,
  and it is the tenant-tier catalog surface, not itself a tenant record. It is the
  `tnt`-namespaced object catalog — the tenant parallel to `tam_table` (system
  table catalog).

  ## The one-way boundary (T3.9)

  There is deliberately **no FK** from any *system* table into `tnt_object` or
  `tnt_record`. The tenant regime may reference OUT to system rows (as validated
  opaque IDs in `tnt_record.tnr_refs`), but the system regime never references IN
  to the tenant regime. Enforced structurally (no FK on these tables) and by the
  one-way-boundary verifier (`mix samen.verify.tnt_boundary` /
  `Samen.Verifiers.TntBoundary`): a system resource declaring a relationship to
  `Samen.CustomObjects.Record` fails.

  ## Columns

    * `tnt_org_id`     — the owning org (the tenant boundary; every custom object is
      org-scoped, vision doc §"every record is org-scoped by policy").
    * `tnt_object_key` — the logical object key (e.g. `"vaccine_lot"`). UNIQUE per
      org. The record bag validates against `tnt_field` rows on the synthetic table
      name derived from this key.
    * `tnt_label`      — a human label (e.g. `"Vaccine Lot"`).
    * `tnt_enabled`    — soft-disable (a Tier-0-style config toggle) without
      deleting the object's records.
  """
  use Ecto.Schema

  @primary_key {:tnt_id, :binary_id, autogenerate: true}
  schema "tnt_object" do
    field(:tnt_org_id, :binary_id)
    field(:tnt_object_key, :string)
    field(:tnt_label, :string)
    field(:tnt_enabled, :boolean, default: true)
    timestamps(type: :utc_datetime_usec)
  end
end
