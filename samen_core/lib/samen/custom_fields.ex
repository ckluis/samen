defmodule Samen.CustomFields do
  @moduledoc """
  Tier-1 tenant custom fields (plan T3.8; vision doc §core "Tier-1 jsonb bag +
  `tnt_field` metadata"; malleability ladder rung 2).

  The bottom-but-one rung of the malleability ladder: an org bends the data model
  by defining **custom fields** inside a resource's `xxx_custom` jsonb bag —
  *without* forking the product, *without* a migration, and *without* escaping the
  system's guarantees. Each such field is:

    * **defined** at runtime (`define_field/1`) with a name, a bounded type, and
      per-type constraints, catalogued into `tnt_field` (org-scoped);
    * **validated-at-write** (`validate_bag/3`, wired via
      `Samen.CustomFields.Change`): every write to the bag is checked against the
      org's `tnt_field` definitions — an undefined key, a wrong-typed value, or a
      constraint violation is **rejected at write**, before it reaches Postgres;
    * **contained** (`classify_containment/2`): a value matching the
      `Samen.PiiValueShape` heuristics on a field NOT declared `pii_declared: true`
      is **rejected** (fail-closed). A Tier-1 field can never be a vault bypass.

  ## The honest edge (vision doc §limits "System is provable; tenant is best-effort")

  This is validated-at-write and contained to a jsonb zone — strong and sealed,
  but NOT the compile-time proof the system core enjoys. `tnt_field` is the
  `tnt`-namespaced catalog surface that makes the customization *governed so it
  doesn't rot* (vision doc §"Every custom field is catalogued"), the seam is
  named, not hidden.

  ## Storage

  `tnt_field` is a plain Ecto DDL table (`Samen.CustomFields.FieldRow`), same
  bootstrap reasoning as `tam_table`/`fld_field`. The bag itself is an ordinary
  `:map` attribute named `:custom`, abbrev-prefixed to `xxx_custom` by the base
  macro — no FK from any system table references bag *content* (the jsonb zone is
  sealed).
  """

  alias Samen.CustomFields.FieldRow
  alias Samen.PiiValueShape

  require Ecto.Query

  @typedoc "A bounded custom-field value type."
  @type field_type ::
          :string
          | :integer
          | :number
          | :boolean
          | :date
          | :enum
          | :money
          | :url
          | :phone
          | :email
          | :address

  # The bounded set of custom-field value types. An unknown type is rejected at
  # definition time — the tenant cannot smuggle in an arbitrary type the
  # validator can't reason about (closed-world, fail-closed).
  #
  # ADR-036 D6/H6: `money`/`url`/`phone`/`email`/`address` reuse the matching
  # `Samen.Type.*` module's OWN cast/validation logic (Money/URL/PhoneNumber/
  # EmailAddress/Address — the same modules H1-H4 gave the Ash resource attribute
  # surface) — same bounded-constraint discipline as the pre-existing six, not a
  # parallel reimplementation.
  @field_types [
    :string,
    :integer,
    :number,
    :boolean,
    :date,
    :enum,
    :money,
    :url,
    :phone,
    :email,
    :address
  ]

  # The logical bag attribute name. The base macro prefixes it to `xxx_custom`.
  @bag_attr :custom

  @doc "The bounded set of custom-field value types."
  @spec field_types() :: [field_type()]
  def field_types, do: @field_types

  @doc "The logical name of the Tier-1 custom bag attribute (`:custom`)."
  @spec bag_attr() :: atom()
  def bag_attr, do: @bag_attr

  # ---------------------------------------------------------------------------
  # Definition (ladder rung 2: an org defines a custom field on a resource)
  # ---------------------------------------------------------------------------

  @doc """
  Define (upsert) a custom field for an org on a resource's bag.

  Options (map or keyword):

    * `:org_id`     — the owning org (required).
    * `:table_name` — the physical table (required), e.g. `"per_person"`.
    * `:field_name` — the bag key (required), e.g. `"loyalty_tier"`.
    * `:type`       — one of `field_types/0` (required).
    * `:constraints` — a map of per-type constraints (optional, default `%{}`).
    * `:pii_declared` — whether the org accepts plaintext-in-bag for this field
      (optional, default `false`). See the moduledoc containment note.

  Returns `{:ok, %FieldRow{}}` or `{:error, reason}`. Fails closed on an unknown
  type or a malformed constraint spec (a definition the validator could not
  enforce is refused, not silently accepted).
  """
  @spec define_field(map() | keyword(), Ecto.Repo.t() | nil) ::
          {:ok, FieldRow.t()} | {:error, term()}
  def define_field(opts, repo \\ nil) do
    opts = Map.new(opts)
    repo = repo || default_repo!()

    with {:ok, org_id} <- fetch(opts, :org_id),
         {:ok, table} <- fetch(opts, :table_name),
         {:ok, field} <- fetch(opts, :field_name),
         {:ok, type} <- fetch(opts, :type),
         {:ok, type} <- validate_type(type),
         constraints = Map.get(opts, :constraints, %{}),
         {:ok, constraints} <- validate_constraint_spec(type, constraints) do
      pii_declared = Map.get(opts, :pii_declared, false) == true

      attrs = %{
        tnt_org_id: to_string(org_id),
        tnt_table_name: to_string(table),
        tnt_field_name: to_string(field),
        tnt_type: Atom.to_string(type),
        tnt_constraints: normalize_constraints(constraints),
        tnt_pii_declared: pii_declared
      }

      row =
        %FieldRow{}
        |> Ecto.Changeset.change(attrs)
        |> repo.insert!(
          on_conflict: {:replace, [:tnt_type, :tnt_constraints, :tnt_pii_declared, :updated_at]},
          conflict_target: [:tnt_org_id, :tnt_table_name, :tnt_field_name]
        )

      {:ok, row}
    end
  end

  @doc """
  List an org's custom-field definitions for a table — the tenant catalog surface
  (parallel to `Samen.Catalog.fields/1` for system columns). Returns `FieldRow`
  structs, sorted by field name for deterministic output.
  """
  @spec list_fields(binary(), binary(), Ecto.Repo.t() | nil) :: [FieldRow.t()]
  def list_fields(org_id, table_name, repo \\ nil) do
    repo = repo || default_repo!()

    FieldRow
    |> Ecto.Query.where(tnt_org_id: ^to_string(org_id), tnt_table_name: ^to_string(table_name))
    |> Ecto.Query.order_by([f], f.tnt_field_name)
    |> repo.all()
  end

  @doc """
  Fetch a single field definition, or `nil`.
  """
  @spec get_field(binary(), binary(), binary(), Ecto.Repo.t() | nil) :: FieldRow.t() | nil
  def get_field(org_id, table_name, field_name, repo \\ nil) do
    repo = repo || default_repo!()

    FieldRow
    |> Ecto.Query.where(
      tnt_org_id: ^to_string(org_id),
      tnt_table_name: ^to_string(table_name),
      tnt_field_name: ^to_string(field_name)
    )
    |> repo.one()
  end

  # ---------------------------------------------------------------------------
  # Validation-at-write (T3.8 (b))
  # ---------------------------------------------------------------------------

  @doc """
  Validate a whole custom bag (`%{key => value}`) for an org against its
  `tnt_field` definitions on `table_name`.

  Returns `:ok` when every key is defined AND every value passes its type +
  constraint checks AND the PII-shape containment rule. Returns
  `{:error, [violation]}` otherwise (all violations, not just the first — a host
  fixing one gets the whole list).

  Each violation is `{field_name, reason}` where `reason` is one of:

    * `{:undefined, "no tnt_field definition"}` — an org wrote a key it never
      defined (catalog-parity: every custom field must be catalogued).
    * `{:type, expected}`                        — wrong-typed value.
    * `{:constraint, detail}`                    — constraint violated.
    * `{:pii_shaped, shape}`                      — CONTAINMENT: a PII-shaped value
      on a field not declared `pii_declared: true` (fail-closed rejection).
  """
  @spec validate_bag(binary(), binary(), map(), Ecto.Repo.t() | nil) ::
          :ok | {:error, [{String.t(), term()}]}
  def validate_bag(org_id, table_name, bag, repo \\ nil)

  def validate_bag(_org_id, _table_name, bag, _repo)
      when not is_map(bag) or bag == %{} do
    # An empty / nil bag is trivially valid — a resource with no custom writes is
    # unaffected. (A non-map is rejected by the schema; here we treat it as empty.)
    :ok
  end

  def validate_bag(org_id, table_name, bag, repo) do
    repo = repo || default_repo!()
    defs = list_fields(org_id, table_name, repo) |> Map.new(&{&1.tnt_field_name, &1})

    violations =
      bag
      |> Enum.flat_map(fn {key, value} ->
        key = to_string(key)

        case Map.get(defs, key) do
          nil ->
            # RED PATH: a custom field with no tnt_field row is invisible to the
            # catalog — reject (governed customization: every field catalogued).
            [{key, {:undefined, "no tnt_field definition for #{inspect(key)}"}}]

          %FieldRow{} = def ->
            validate_value(def, value) |> Enum.map(&{key, &1})
        end
      end)

    if violations == [], do: :ok, else: {:error, violations}
  end

  @doc """
  Validate a single value against one field definition — the type check, the
  constraint checks, and the PII-shape containment check. Returns a (possibly
  empty) list of reasons.
  """
  @spec validate_value(FieldRow.t(), term()) :: [term()]
  def validate_value(%FieldRow{} = def, value) do
    type = String.to_existing_atom(def.tnt_type)

    cond do
      is_nil(value) ->
        # A nil clears the key — always allowed (no shape, no type to check).
        []

      not type_ok?(type, value) ->
        [{:type, def.tnt_type}]

      true ->
        constraint_violations(type, def.tnt_constraints, value) ++
          containment_violations(def, value)
    end
  end

  # ---------------------------------------------------------------------------
  # Containment (T3.8 (d)): a value that LOOKS like PII on a non-PII-declared
  # custom field is REJECTED. Fail-closed default — a Tier-1 field can never be a
  # silent vault bypass.
  # ---------------------------------------------------------------------------

  @doc """
  Classify a value for containment against a field definition.

  Returns `:ok` when the value is safe to store in the bag, or
  `{:reject, shape}` when it is PII-shaped and the field is not declared
  `pii_declared: true`.

  Fail-closed: the default (`pii_declared: false`) rejects PII-shaped values.
  Declaring `pii_declared: true` is an org knowingly accepting plaintext-in-bag —
  it lifts the *rejection*, it does NOT route the value to the vault (Tier-1 is
  contained, not vault-protected — the honest seam).
  """
  # H6/ADR-036 D6: the three PII-BY-TYPE kinds (`email`/`phone`/`address` — the
  # Tier-1 analogues of H3's PII-by-default scalars and H4's always-PII composite).
  # Their whole point is to hold a person's own contact info, so containment gates
  # on the DECLARED TYPE, not merely a value-shape regex match:
  #
  #   * an `:address` value is a MAP — `PiiValueShape.classify_id_value/1` only
  #     ever inspects strings, so without this clause a non-pii_declared address
  #     custom field would sail through the generic binary clause below untouched
  #     (fall to the catch-all `:ok`) — a real vault-bypass hole for a composite.
  #   * a valid, freshly-normalized `:phone`/`:email` value USUALLY also matches
  #     the shape heuristic below, but that is a coincidence of the two regex
  #     families overlapping, not a guarantee (e.g. an 8-digit E.164-ish number
  #     `Samen.Type.PhoneNumber` accepts is shorter than the heuristic's assumed
  #     3-3-4 grouping and would NOT match it).
  #
  # So: ANY non-nil value on a non-pii_declared email/phone/address custom field is
  # refused, full stop — "a custom email/phone/address field can never become a
  # vault bypass" (H6 contract) is made true by type, not by hoping the value
  # happens to look PII-shaped. Ordered BEFORE the generic binary clause so it wins
  # for email/phone (both binary-valued).
  @spec classify_containment(FieldRow.t(), term()) :: :ok | {:reject, atom()}
  def classify_containment(%FieldRow{tnt_pii_declared: true}, _value), do: :ok

  # ADR-036 D1/D2 — `money`/`url` are non-PII BY TYPE (the same posture their Ash
  # attribute counterparts get via the foundry `TypeClearance`, ADR-034): their
  # value-shape is already fully bounded by `type_ok?/2` (a parsed money amount, a
  # parsed absolute URL), so the GENERIC value-shape heuristic below is not just
  # unnecessary but actively wrong here — a canonical money cell ("USD 1234.50")
  # has an internal space and would otherwise false-positive the heuristic's
  # `name_shaped?/1` check. Explicitly exempt them rather than let a coincidental
  # regex collision reject a legitimate, categorically-non-PII value.
  def classify_containment(%FieldRow{tnt_pii_declared: false, tnt_type: type}, _value)
      when type in ["money", "url"] do
    :ok
  end

  def classify_containment(%FieldRow{tnt_pii_declared: false, tnt_type: type}, value)
      when type in ["email", "phone", "address"] and not is_nil(value) do
    {:reject, String.to_existing_atom(type)}
  end

  def classify_containment(%FieldRow{tnt_pii_declared: false}, value) when is_binary(value) do
    case PiiValueShape.classify_id_value(value) do
      {true, shape} -> {:reject, shape}
      {false, _} -> :ok
    end
  end

  def classify_containment(%FieldRow{}, _value), do: :ok

  defp containment_violations(def, value) do
    case classify_containment(def, value) do
      :ok -> []
      {:reject, shape} -> [{:pii_shaped, shape}]
    end
  end

  # ---------------------------------------------------------------------------
  # Type + constraint checking
  # ---------------------------------------------------------------------------

  defp type_ok?(:string, v), do: is_binary(v)
  defp type_ok?(:integer, v), do: is_integer(v)
  # A number accepts integer or float.
  defp type_ok?(:number, v), do: is_number(v)
  defp type_ok?(:boolean, v), do: is_boolean(v)
  # enum values are stored as strings in jsonb.
  defp type_ok?(:enum, v), do: is_binary(v)

  defp type_ok?(:date, v) when is_binary(v) do
    match?({:ok, _}, Date.from_iso8601(v))
  end

  defp type_ok?(:date, %Date{}), do: true
  defp type_ok?(:date, _), do: false

  # ADR-036 D6/H6 — delegate the SHAPE check to the matching `Samen.Type.*`
  # module's own `cast_input/2` (no constraints), reusing its format/parse rules
  # verbatim rather than re-deriving them. The canonical bag-stored forms mirror
  # D5's CSV cell forms: money/url/phone/email are the plain string forms; address
  # is the raw (already-decoded) map — the bag is jsonb, so no extra JSON-string
  # encoding step is needed the way a CSV cell needs one.
  defp type_ok?(:money, v) when is_binary(v), do: match?({:ok, _}, Samen.Type.Money.cast_input(v, []))
  defp type_ok?(:money, _), do: false

  defp type_ok?(:url, v) when is_binary(v), do: match?({:ok, _}, Samen.Type.URL.cast_input(v, []))
  defp type_ok?(:url, _), do: false

  defp type_ok?(:phone, v) when is_binary(v),
    do: match?({:ok, _}, Samen.Type.PhoneNumber.cast_input(v, []))

  defp type_ok?(:phone, _), do: false

  defp type_ok?(:email, v) when is_binary(v),
    do: match?({:ok, _}, Samen.Type.EmailAddress.cast_input(v, []))

  defp type_ok?(:email, _), do: false

  defp type_ok?(:address, v) when is_map(v),
    do: match?({:ok, _}, Samen.Type.Address.cast_input(v, []))

  defp type_ok?(:address, _), do: false

  defp constraint_violations(:string, constraints, value) do
    max = constraints["max_length"]
    min = constraints["min_length"]

    []
    |> maybe(max && String.length(value) > max, {:constraint, {:max_length, max}})
    |> maybe(min && String.length(value) < min, {:constraint, {:min_length, min}})
  end

  defp constraint_violations(type, constraints, value) when type in [:integer, :number] do
    max = constraints["max"]
    min = constraints["min"]

    []
    |> maybe(is_number(max) && value > max, {:constraint, {:max, max}})
    |> maybe(is_number(min) && value < min, {:constraint, {:min, min}})
  end

  defp constraint_violations(:enum, constraints, value) do
    case constraints["one_of"] do
      list when is_list(list) ->
        if value in list, do: [], else: [{:constraint, {:one_of, list}}]

      _ ->
        # An enum with no one_of is a definition-time error caught by
        # validate_constraint_spec; be defensive here.
        [{:constraint, {:one_of, :undefined}}]
    end
  end

  # ADR-036 D6/H6 bounded constraints for the five new kinds — each reuses the
  # matching `Samen.Type.*` module's OWN `cast_input/2` + `constraints/0` shape
  # (passing the tenant's `tnt_constraints` straight through as the type's
  # constraints keyword list) wherever that type already has a bounded-constraint
  # story (URL's `schemes`/`max_length`; phone/email's `max_length`); `money` and
  # `address` gain a Tier-1-level bound the Ash type itself does not carry
  # (`currencies` / `allowed_countries` allowlists) — the same "additional bound
  # beyond the base shape" role `min`/`max`/`one_of` play for :integer/:number/:enum.
  defp constraint_violations(:money, constraints, value) do
    case constraints["currencies"] do
      list when is_list(list) and list != [] ->
        case Samen.Type.Money.cast_input(value, []) do
          {:ok, %Money{currency: currency}} ->
            code = currency |> to_string() |> String.upcase()
            if code in list, do: [], else: [{:constraint, {:currencies, list}}]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp constraint_violations(:url, constraints, value) do
    kw =
      []
      |> put_constraint(:schemes, constraints["schemes"])
      |> put_constraint(:max_length, constraints["max_length"])

    if kw == [] do
      []
    else
      case Samen.Type.URL.cast_input(value, kw) do
        {:ok, _} -> []
        :error -> [{:constraint, {:url, Map.new(kw)}}]
      end
    end
  end

  defp constraint_violations(:phone, constraints, value) do
    case constraints["max_length"] do
      max when is_integer(max) ->
        case Samen.Type.PhoneNumber.cast_input(value, max_length: max) do
          {:ok, _} -> []
          :error -> [{:constraint, {:max_length, max}}]
        end

      _ ->
        []
    end
  end

  defp constraint_violations(:email, constraints, value) do
    case constraints["max_length"] do
      max when is_integer(max) ->
        case Samen.Type.EmailAddress.cast_input(value, max_length: max) do
          {:ok, _} -> []
          :error -> [{:constraint, {:max_length, max}}]
        end

      _ ->
        []
    end
  end

  defp constraint_violations(:address, constraints, value) do
    case constraints["allowed_countries"] do
      list when is_list(list) and list != [] ->
        case Samen.Type.Address.cast_input(value, []) do
          {:ok, %Samen.Type.Address{country: country}} ->
            if is_nil(country) or country in list do
              []
            else
              [{:constraint, {:allowed_countries, list}}]
            end

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp constraint_violations(_type, _constraints, _value), do: []

  defp put_constraint(kw, _key, nil), do: kw
  defp put_constraint(kw, key, value), do: Keyword.put(kw, key, value)

  defp maybe(list, true, violation), do: [violation | list]
  defp maybe(list, _false, _violation), do: list

  # ---------------------------------------------------------------------------
  # Definition-time validation (fail-closed on a spec the validator can't enforce)
  # ---------------------------------------------------------------------------

  defp validate_type(type) when is_atom(type) do
    if type in @field_types, do: {:ok, type}, else: {:error, {:unknown_type, type}}
  end

  defp validate_type(type) when is_binary(type) do
    case Enum.find(@field_types, &(Atom.to_string(&1) == type)) do
      nil -> {:error, {:unknown_type, type}}
      atom -> {:ok, atom}
    end
  end

  defp validate_type(type), do: {:error, {:unknown_type, type}}

  # An :enum field MUST declare a non-empty one_of list — otherwise no value could
  # ever be valid and the definition is meaningless. Fail closed at define time.
  defp validate_constraint_spec(:enum, constraints) do
    case normalize_constraints(constraints)["one_of"] do
      list when is_list(list) and list != [] -> {:ok, constraints}
      _ -> {:error, {:invalid_constraint, "enum requires a non-empty one_of list"}}
    end
  end

  defp validate_constraint_spec(_type, constraints) when is_map(constraints), do: {:ok, constraints}
  defp validate_constraint_spec(_type, _), do: {:error, {:invalid_constraint, "must be a map"}}

  # Normalize constraint keys to strings (jsonb round-trips as string keys, so the
  # in-memory definition must match what comes back from the DB).
  defp normalize_constraints(constraints) when is_map(constraints) do
    Map.new(constraints, fn {k, v} -> {to_string(k), v} end)
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
    Application.get_env(:samen_core, :vault_repo) ||
      raise "Samen.CustomFields: no repo configured. Set :samen_core, :vault_repo or pass a repo."
  end
end
