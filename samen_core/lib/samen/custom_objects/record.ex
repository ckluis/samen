defmodule Samen.CustomObjects.Record do
  @moduledoc """
  `tnt_record` — a **Tier-2 tenant custom-object row** (plan T3.9; vision doc §core
  "custom OBJECTS in `tnt_record`"; malleability ladder rung 3).

  This is the one place in the Tier-2 stack that is a real **Ash resource** (the
  catalog tables `tnt_object`/`tnt_field` are plain DDL). Being an Ash resource is
  deliberate: it inherits, for free, the two guarantees a tenant record needs —

    * **org-scope** — `Samen.Policy.OrgScope` filters every read/write to the
      acting org, so a cross-org `tnt_record` read returns `[]` (rows from other
      orgs are invisible, not merely forbidden). This is the T3.9 red path
      "cross-org tnt_record read denied".
    * **abbrev storage** — the base macro prefixes every column `tnr_*`
      (`tnr_org_id`, `tnr_object_key`, `tnr_attributes`, `tnr_refs`) so the
      Tier-2 rows sit under the same self-qualifying storage discipline as system
      rows (catalog/CDC/logs see prefixed names).

  ## The attributes bag — validated-at-write, reusing Tier-1 machinery

  `attributes` is the validated jsonb bag (abbrev `tnr_attributes`). Its keys are
  the object's custom *fields* — `tnt_field` rows whose `tnt_table_name` is the
  object's synthetic table name (`Samen.CustomObjects.object_table/1`). Every write
  is validated by `Samen.CustomObjects.RecordChange`, which delegates to
  `Samen.CustomFields.validate_bag/4` — the SAME validated-at-write engine T3.8
  built (type checks, per-type constraints, and PII-shape containment). So the
  T3.9 red paths "invalid attribute shape rejected" and "PII-shaped value rejected"
  are the Tier-1 guarantees, reused verbatim. A record whose object has no defined
  fields accepts an empty bag but rejects any key (fail-closed: an undefined key is
  an uncatalogued custom field).

  ## The refs bag — opaque OUT-references only (the one-way boundary)

  `refs` (abbrev `tnr_refs`) holds references OUT to system rows, e.g.
  `%{"owner_role" => "<uuid>"}`. These are **validated opaque IDs**, stored as
  data — NOT Postgres foreign keys. A `tnt_record` may point at a system row; the
  system schema never points back (no FK from a system table into `tnt_record`,
  and no system Ash resource may declare a relationship to this module — enforced
  by `Samen.Verifiers.TntBoundary` / `mix samen.verify.tnt_boundary`). The
  `RecordChange` validates that every ref value is opaque-ID-shaped, so a
  PII-shaped or free-text ref is rejected — a ref can never smuggle a name across
  the boundary as a "reference".

  ## Why not one physical table per custom object

  Twenty's metadata model provisions a real table per custom object via runtime
  dynamic DDL. The vision doc REJECTS that (§"Twenty CRM = a SPEC, not a
  dependency": adopt the taxonomy, reject the inverse source-of-truth). Samen keeps
  ONE `tnt_record` table, keyed by `object_key`, with a validated jsonb bag — the
  system schema stays compile-time provable and the tenant regime stays contained
  to the sealed jsonb zone, never issuing DDL at runtime.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.CustomObjects.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "tnr"

  postgres do
    table("tnt_record")
    repo(Application.compile_env(:samen_core, :tnt_record_repo, SamenCore.TestRepo))
  end

  attributes do
    # The object this record belongs to — the tenant object key (e.g.
    # "vaccine_lot"). Its fields (and thus the attributes bag validation) are the
    # tnt_field rows on the object's synthetic table name.
    attribute(:object_key, :string, public?: true, allow_nil?: false)

    # The validated jsonb bag of custom-object attributes.
    attribute(:attributes, :map, public?: true, default: %{})

    # Opaque OUT-references to system rows (validated opaque IDs; NOT FKs).
    attribute(:refs, :map, public?: true, default: %{})
  end

  actions do
    defaults([:read, :destroy, create: :*, update: :*])
  end

  changes do
    change(Samen.CustomObjects.RecordChange)
  end

  policies do
    # Every tenant custom-object read/write is org-scoped — the T3.9 red path
    # "cross-org tnt_record read denied" is this filter (a cross-org read returns
    # no rows; an org-less actor sees nothing, fail closed).
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(Samen.Policy.OrgScope)
    end
  end
end
