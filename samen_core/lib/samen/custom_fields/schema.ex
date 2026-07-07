defmodule Samen.CustomFields.FieldRow do
  @moduledoc """
  Ecto schema for a `tnt_field` row — the **Tier-1 tenant custom-field catalog**
  (plan T3.8; vision doc §core "Tier-1 jsonb bag + `tnt_field` metadata",
  malleability ladder rung 2 "custom fields", §"Every custom field is catalogued").

  ## What `tnt_field` is — and how it differs from `fld_field`

  `fld_field` catalogues the **system** columns: the abbrev-prefixed physical
  columns that Ash + the base macro emit, provable at compile time
  (`mix samen.verify.catalog_parity`). Those are the *system regime*.

  `tnt_field` catalogues the **tenant** custom fields: keys an org has defined
  inside a resource's `xxx_custom` jsonb bag. It is the `tnt`-namespaced
  parallel to `fld_field`. The honest-edge distinction the vision doc names
  ("System is provable; tenant is best-effort"):

    * `fld_field`  — one row per physical column, **not** org-scoped, compile-time
      provable, no PII values ever (columns route to the vault by declaration).
    * `tnt_field`  — one row per `(org, table, field)` custom-field *definition*,
      **org-scoped** (`tnt_org_id`), validated-at-write, contained to the jsonb
      zone. A custom field is metadata *about* a bag key, never a real column.

  Both are plain Ecto DDL tables (not Ash resources) — same bootstrap reasoning
  as the catalog tables (`Samen.Catalog` moduledoc): you cannot catalog the
  catalog with the catalog mechanism, and `tnt_field` must exist before any bag
  write is validated against it.

  ## Columns

    * `tnt_org_id`      — the owning org (the tenant boundary; every custom field
      is org-scoped, vision doc §"every record is org-scoped by policy").
    * `tnt_table_name`  — the physical table the bag lives on (e.g. `per_person`),
      the same key `fld_field` uses, so the two catalogs join on table.
    * `tnt_field_name`  — the bag key (logical, e.g. `"loyalty_tier"`). Unqualified
      by abbrev: it is a jsonb key, not a physical column.
    * `tnt_type`        — the declared value type: one of
      `Samen.CustomFields.field_types/0` (`string`/`integer`/`number`/`boolean`/
      `date`/`enum`). Bounded — an unknown type is rejected at definition time.
    * `tnt_constraints` — a jsonb map of per-type constraints (e.g.
      `{"max_length": 40}`, `{"one_of": ["gold","silver"]}`, `{"min": 0}`).
    * `tnt_pii_declared` — whether this custom field is *declared* to hold PII.
      **Default false.** The containment rule (T3.8 (d)): a value matching
      `Samen.PiiValueShape` on a field where this is `false` is REJECTED at write
      (fail-closed). A Tier-1 field can never be a vault bypass: even when
      `true`, the value is stored in the (sealed) jsonb bag, never routed to the
      vault — declaring `pii_declared: true` only *lifts the shape rejection* for
      an org that has knowingly accepted plaintext-in-bag, it does not grant vault
      protection. (The honest seam: Tier-1 is validated-at-write and contained,
      not the same proof as a system `pii_attribute`.)

  There is deliberately **no FK** from any system table into a custom-field
  *value*: `tnt_field` describes bag keys, and the bag is a `:map` column. The
  jsonb zone is sealed — nothing in the system schema references bag content
  (T3.8 (d) "no FK from system tables into bag content").
  """
  use Ecto.Schema

  @primary_key {:tnt_id, :binary_id, autogenerate: true}
  schema "tnt_field" do
    field(:tnt_org_id, :binary_id)
    field(:tnt_table_name, :string)
    field(:tnt_field_name, :string)
    field(:tnt_type, :string)
    field(:tnt_constraints, :map, default: %{})
    field(:tnt_pii_declared, :boolean, default: false)
    timestamps(type: :utc_datetime_usec)
  end
end
