defmodule Samen.CustomObjects do
  @moduledoc """
  Tier-2 tenant custom objects — **minimal viable** (plan T3.9, risk R11; vision
  doc §core "custom OBJECTS in `tnt_record` + `tnt_object`/`tnt_field`", malleability
  ladder rung 3; Twenty's metadata model as the SPEC only).

  The third rung of the malleability ladder. Where Tier-0 is config rows and Tier-1
  is custom *fields* on system resources (`Samen.CustomFields`, T3.8), Tier-2 lets
  an org define a whole custom *object* it invented — the vision doc's canonical
  example, a clinic's `VaccineLot` — and store rows of it. All three tiers stay
  inside the tenant regime: **validated-at-write, contained, one-way boundary** —
  never the compile-time proof the system core enjoys.

  ## The pieces (and how they reuse T3.8)

    * `tnt_object` (`Samen.CustomObjects.ObjectRow`, plain DDL) — the org-scoped
      object-definition catalog. `define_object/2` upserts one.
    * `tnt_field`  (`Samen.CustomFields.FieldRow`, SHARED with T3.8) — a custom
      object's fields ARE Tier-1 custom fields, keyed on the object's synthetic
      table name (`object_table/1`). Define them with
      `Samen.CustomObjects.define_object_field/2` (a thin wrapper over
      `Samen.CustomFields.define_field/2`).
    * `tnt_record` (`Samen.CustomObjects.Record`, an org-scoped Ash resource) — the
      rows. Its `attributes` bag is validated by the SAME engine
      (`Samen.CustomFields.validate_bag/4`); its `refs` bag holds opaque OUT-refs.

  ## CRUD

  Records CRUD through the ordinary Ash API on `Samen.CustomObjects.Record`, scoped
  by a `%Samen.Scope{}` actor (so org-scope policy applies). Thin helpers
  (`create_record/3`, `list_records/3`) wrap the common cases. Because `Record` is
  an Ash resource with `Samen.Policy.OrgScope`, a cross-org read returns `[]` — the
  T3.9 "cross-org tnt_record read denied" red path is a policy consequence, not a
  bespoke check.

  ## The one-way boundary (T3.9 — documented AND enforced)

  Data may reference OUT of the tenant regime into the system regime (a
  `tnt_record.refs` entry pointing at a system row id, validated as an opaque ID),
  but NEVER the reverse:

    * **structural** — no FK exists on `tnt_object`/`tnt_record` pointing at a
      system table, and no system table has an FK into them.
    * **compile-time** — `Samen.Verifiers.TntBoundary` (a Spark verifier, and
      `mix samen.verify.tnt_boundary`) fails if any *system* Ash resource declares
      a relationship (`belongs_to`/`has_many`/`has_one`/`many_to_many`) targeting
      `Samen.CustomObjects.Record`. A system resource reaching INTO the tenant
      regime is the exact inversion the boundary forbids (this is the T3.9 red
      path "one-way-boundary compile/verifier check").
    * **value-shape** — `Samen.CustomObjects.RecordChange` rejects a PII-shaped or
      free-text ref, so an OUT-ref can only be an opaque ID.
  """

  alias Samen.CustomFields
  alias Samen.CustomObjects.ObjectRow

  require Ecto.Query

  # Synthetic-table-name prefix for a custom object's fields. A custom object's
  # `tnt_field` rows use this as their `tnt_table_name`, so the object's field
  # namespace is disjoint from any physical system table (which never starts with
  # this prefix). Deliberately a `tnt$` sentinel that no real abbrev-prefixed table
  # can collide with (abbrevs are `[a-z]{3}`, tables are `<abbrev>_<name>`).
  @object_table_prefix "tnt$obj$"

  @doc """
  The synthetic `tnt_field.tnt_table_name` for a custom object's fields.

  A custom object `"vaccine_lot"` stores its field definitions as `tnt_field` rows
  with `tnt_table_name = "tnt$obj$vaccine_lot"`. This keeps the object's field
  namespace disjoint from every physical system table (none begins with the
  sentinel prefix), so the Tier-1 `tnt_catalog` bag-scan (which walks *physical*
  managed tables) never touches these rows, and vice versa.
  """
  @spec object_table(binary()) :: binary()
  def object_table(object_key), do: @object_table_prefix <> to_string(object_key)

  @doc "The synthetic-table sentinel prefix (see `object_table/1`)."
  @spec object_table_prefix() :: binary()
  def object_table_prefix, do: @object_table_prefix

  # ---------------------------------------------------------------------------
  # Object definition (ladder rung 3: an org defines a custom object)
  # ---------------------------------------------------------------------------

  @doc """
  Define (upsert) a custom object for an org.

  Options (map or keyword):

    * `:org_id`     — the owning org (required).
    * `:object_key` — the logical object key, e.g. `"vaccine_lot"` (required).
    * `:label`      — a human label (optional).
    * `:enabled`    — whether the object is active (optional, default `true`).

  Returns `{:ok, %ObjectRow{}}` or `{:error, reason}`.
  """
  @spec define_object(map() | keyword(), Ecto.Repo.t() | nil) ::
          {:ok, ObjectRow.t()} | {:error, term()}
  def define_object(opts, repo \\ nil) do
    opts = Map.new(opts)
    repo = repo || default_repo!()

    with {:ok, org_id} <- fetch(opts, :org_id),
         {:ok, key} <- fetch(opts, :object_key) do
      attrs = %{
        tnt_org_id: to_string(org_id),
        tnt_object_key: to_string(key),
        tnt_label: Map.get(opts, :label),
        tnt_enabled: Map.get(opts, :enabled, true) == true
      }

      row =
        %ObjectRow{}
        |> Ecto.Changeset.change(attrs)
        |> repo.insert!(
          on_conflict: {:replace, [:tnt_label, :tnt_enabled, :updated_at]},
          conflict_target: [:tnt_org_id, :tnt_object_key]
        )

      {:ok, row}
    end
  end

  @doc """
  Define a field ON a custom object (a Tier-1 `tnt_field` under the object's
  synthetic table name). Thin wrapper over `Samen.CustomFields.define_field/2`
  that fills in `table_name` — so a custom object's fields reuse the T3.8
  machinery exactly (type + constraints + PII-shape containment).

  Requires `:org_id`, `:object_key`, `:field_name`, `:type`; passes `:constraints`
  and `:pii_declared` through.
  """
  @spec define_object_field(map() | keyword(), Ecto.Repo.t() | nil) ::
          {:ok, CustomFields.FieldRow.t()} | {:error, term()}
  def define_object_field(opts, repo \\ nil) do
    opts = Map.new(opts)

    with {:ok, object_key} <- fetch(opts, :object_key) do
      opts
      |> Map.delete(:object_key)
      |> Map.put(:table_name, object_table(object_key))
      |> CustomFields.define_field(repo)
    end
  end

  @doc """
  List an org's custom-object definitions. Returns `ObjectRow` structs, sorted by
  object key. This IS the tenant-tier object catalog (the `tnt`-namespaced parallel
  to the system `tam_table` catalog).
  """
  @spec list_objects(binary(), Ecto.Repo.t() | nil) :: [ObjectRow.t()]
  def list_objects(org_id, repo \\ nil) do
    repo = repo || default_repo!()

    ObjectRow
    |> Ecto.Query.where(tnt_org_id: ^to_string(org_id))
    |> Ecto.Query.order_by([o], o.tnt_object_key)
    |> repo.all()
  end

  @doc "Fetch a single object definition, or `nil`."
  @spec get_object(binary(), binary(), Ecto.Repo.t() | nil) :: ObjectRow.t() | nil
  def get_object(org_id, object_key, repo \\ nil) do
    repo = repo || default_repo!()

    ObjectRow
    |> Ecto.Query.where(
      tnt_org_id: ^to_string(org_id),
      tnt_object_key: ^to_string(object_key)
    )
    |> repo.one()
  end

  @doc """
  Is there an ENABLED `tnt_object` for `(org, object_key)`? Used by
  `Samen.CustomObjects.RecordChange` to gate a record write (fail closed: an
  undefined or disabled object rejects the write).
  """
  @spec object_enabled?(binary(), binary(), Ecto.Repo.t() | nil) :: boolean()
  def object_enabled?(org_id, object_key, repo \\ nil) do
    case get_object(org_id, object_key, repo) do
      %ObjectRow{tnt_enabled: true} -> true
      _ -> false
    end
  end

  @doc """
  List an object's field definitions (the object's Tier-1 `tnt_field` rows). The
  tenant field catalog for one custom object.
  """
  @spec list_object_fields(binary(), binary(), Ecto.Repo.t() | nil) :: [CustomFields.FieldRow.t()]
  def list_object_fields(org_id, object_key, repo \\ nil) do
    CustomFields.list_fields(org_id, object_table(object_key), repo)
  end

  # ---------------------------------------------------------------------------
  # Record CRUD (through the org-scoped Ash resource)
  # ---------------------------------------------------------------------------

  @doc """
  Create a record of a custom object for the scope's org. `attrs` is the validated
  attributes bag; `opts` may carry `:refs` (opaque OUT-references).

  Goes through the ordinary Ash create with the scope's actor, so org-scope policy
  and the `RecordChange` validation both apply. `org_id` is set from the scope.
  """
  @spec create_record(Samen.Scope.t(), binary(), map(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def create_record(%Samen.Scope{} = scope, object_key, attrs, opts \\ []) do
    org_id = scope.actor.org_id
    refs = Keyword.get(opts, :refs, %{})

    Samen.CustomObjects.Record
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      object_key: to_string(object_key),
      attributes: attrs,
      refs: refs
    })
    |> Ash.create(scope: scope)
  end

  @doc """
  List a scope's records of a custom object. Org-scoped by policy (a cross-org read
  returns `[]`). Returns `{:ok, [record]}` or `{:error, _}`.
  """
  @spec list_records(Samen.Scope.t(), binary(), keyword()) :: {:ok, [struct()]} | {:error, term()}
  def list_records(%Samen.Scope{} = scope, object_key, _opts \\ []) do
    require Ash.Query

    Samen.CustomObjects.Record
    |> Ash.Query.filter(object_key == ^to_string(object_key))
    |> Ash.Query.ensure_selected([:org_id, :object_key, :attributes, :refs])
    |> Ash.read(scope: scope)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fetch(opts, key) do
    case Map.get(opts, key) do
      nil -> {:error, {:missing, key}}
      value -> {:ok, value}
    end
  end

  defp default_repo! do
    Application.get_env(:samen_core, :tnt_record_repo) ||
      Application.get_env(:samen_core, :vault_repo) ||
      raise "Samen.CustomObjects: no repo configured. Set :samen_core, :tnt_record_repo or :vault_repo."
  end
end
