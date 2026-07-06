defmodule Samen.PiiClassify do
  @moduledoc """
  Heuristic scanner for the `pii_classify` verifier (plan C4; T1.8c).

  Implements the two-axis heuristic specified in the vision doc §llm backstop
  paragraph:

    1. **Identifier-shape name**: the column's logical name matches a known PII
       identifier pattern (`ssn`, `dob`, `mrn`, `cdl`, `tax_id`, `email`,
       `phone`, …). Match is substring-based — `:user_email` and
       `:email_address` both hit the `email` pattern.

    2. **PII-shaped seed/sample values**: the attribute's `:default` or
       `:constraints` carry a value that looks like an email address, an SSN,
       or a phone number.

  **Flag-on-hit, NOT assume-every-string-is-PII.** Only `:string` and `:date`
  attributes that satisfy at least one axis get flagged. All other types pass
  through without comment (type-level classification is `Samen.Pii.Classification`'s
  job).

  ## "New" semantics

  "New" means the column is NOT present in the committed `schema.dict.json`
  baseline. If no baseline file is found, ALL plain-typed columns on the resource
  are considered new (pre-existing reviewed columns do not re-flag).

  The verifier (`Mix.Tasks.Samen.Verify.PiiClassify`) loads the baseline; this
  module is pure: it receives the baseline set as a parameter.

  ## Override

  A column can be cleared in two ways:

    * Declare it in a `pii do … end` block as `pii_attribute` → vault-routed.
    * Register a `non_pii!` override via `Samen.NonPii.register/1` with DISTINCT
      second-reviewer metadata (`cleared_by != reviewed_by`). A self-review
      override (same author and reviewer) fails here and in `Samen.NonPii`.

  Both facts are checked via the runtime registry; the verifier calls this
  module after loading the registry.
  """

  alias Samen.Pii.Info, as: PiiInfo

  @typedoc "A flagged column with the reason(s) it was flagged."
  @type flag :: %{
          resource: module(),
          table_name: String.t(),
          column_name: String.t(),
          logical_name: atom(),
          type: term(),
          reasons: [String.t()]
        }

  @typedoc "A (table_name, column_name) pair from the baseline."
  @type baseline_set :: MapSet.t({String.t(), String.t()})

  # ---------------------------------------------------------------------------
  # Name patterns (substring match, lowercase)
  # ---------------------------------------------------------------------------

  # Exact-token or substring matches against the logical attribute name.
  # These are the identifiers named in the spec:
  # ssn · dob · mrn · cdl · tax_id · email · phone
  # plus a broader set of common PII field name fragments.
  @pii_name_tokens ~w(
    ssn
    dob
    mrn
    cdl
    tax_id
    taxid
    email
    phone
    mobile
    fax
    npi
    ein
    itin
    passport
    birthdate
    birth_date
    birth_year
    date_of_birth
    national_id
    national_insurance
    social_security
    driver_license
    drivers_license
    license_plate
    license_no
    license_num
    address
    street
    zipcode
    zip_code
    postal_code
    postcode
    ip_address
    mac_address
    device_id
    latitude
    longitude
    biometric
    salary
    income
    account_no
    account_num
    bank_account
    credit_card
    card_number
    routing_number
  )

  # ---------------------------------------------------------------------------
  # Value-shape patterns (for seeded/default values)
  #
  # The email/SSN/phone regexes live in `Samen.PiiValueShape` — the single shared
  # source of truth also used by the J2 runtime guard (`Samen.WideEvent`). This
  # module delegates to it rather than duplicating the regexes (Gate-2 F2.2).
  # ---------------------------------------------------------------------------

  alias Samen.PiiValueShape

  # ---------------------------------------------------------------------------
  # Main API
  # ---------------------------------------------------------------------------

  @doc """
  Scan a single resource module and return flagged columns.

  ## Parameters

    * `resource` — a compiled Ash resource module.
    * `baseline` — a `MapSet.t({table_name, column_name})` of columns that are
      already in the committed `schema.dict.json` baseline (not "new").
    * `registry_entries` — a list of `%Samen.NonPii.Entry{}` rows representing
      accepted `non_pii!` overrides (already cleared in the registry).

  ## Returns

  A list of `flag` maps — one per NEW plain-typed column that hits the heuristic
  AND is neither vault-routed NOR covered by a valid `non_pii!` override.
  An empty list means the resource passes.
  """
  @spec scan_resource(module(), baseline_set(), [term()]) :: [flag()]
  def scan_resource(resource, baseline \\ MapSet.new(), registry_entries \\ []) do
    table = AshPostgres.DataLayer.Info.table(resource)
    vault_routed = vault_routed_names(resource)
    non_pii_cleared = non_pii_cleared_set(registry_entries, table)

    resource
    |> plain_string_or_date_attributes()
    |> Enum.reject(fn attr ->
      # Already in baseline → pre-existing reviewed column, skip.
      col = to_string(attr.source || attr.name)
      MapSet.member?(baseline, {table, col})
    end)
    |> Enum.reject(fn attr ->
      # Vault-routed (declared in pii do block) → cleared.
      MapSet.member?(vault_routed, attr.name)
    end)
    |> Enum.reject(fn attr ->
      # Has a valid non_pii! override (with distinct reviewer).
      col = to_string(attr.source || attr.name)
      MapSet.member?(non_pii_cleared, col)
    end)
    |> Enum.flat_map(fn attr ->
      col = to_string(attr.source || attr.name)
      reasons = flag_reasons(attr)

      if reasons == [] do
        []
      else
        [
          %{
            resource: resource,
            table_name: table,
            column_name: col,
            logical_name: attr.name,
            type: attr.type,
            reasons: reasons
          }
        ]
      end
    end)
  end

  @doc """
  Scan a list of resource modules and return all flagged columns.

  The verifier calls this after loading the baseline and registry.
  """
  @spec scan_resources([module()], baseline_set(), [term()]) :: [flag()]
  def scan_resources(resources, baseline \\ MapSet.new(), registry_entries \\ []) do
    Enum.flat_map(resources, &scan_resource(&1, baseline, registry_entries))
  end

  @doc """
  Check if a logical name (atom or string) matches a PII identifier pattern.

  True if any of the PII name tokens is a substring of the downcased name.
  """
  @spec pii_name?(atom() | String.t()) :: boolean()
  def pii_name?(name) do
    str = name |> to_string() |> String.downcase()
    Enum.any?(@pii_name_tokens, fn token -> String.contains?(str, token) end)
  end

  @doc """
  Check if a string value looks like a PII-shaped value (email, SSN, phone).

  Returns `{true, :email | :ssn | :phone}` on a hit, `{false, nil}` otherwise.
  """
  @spec pii_shaped_value?(String.t()) :: {boolean(), atom() | nil}
  def pii_shaped_value?(value), do: PiiValueShape.classify_value(value)

  @doc """
  Load the committed `schema.dict.json` baseline as a `baseline_set`.

  Returns an empty set if the file does not exist (so all columns are treated
  as new).
  """
  @spec load_baseline(String.t()) :: baseline_set()
  def load_baseline(path \\ "schema.dict.json") do
    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
      |> extract_baseline_pairs()
    else
      MapSet.new()
    end
  end

  @doc """
  Format a flag for human-readable output.
  """
  @spec format_flag(flag()) :: String.t()
  def format_flag(%{} = flag) do
    reasons_str = Enum.join(flag.reasons, "; ")

    "likely-PII column: #{flag.table_name}.#{flag.column_name} " <>
      "(#{flag.resource |> inspect()}, logical :#{flag.logical_name}, " <>
      "type: #{inspect(flag.type)}) — #{reasons_str}"
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Attributes whose type is :string / Ash.Type.String or :date / Ash.Type.Date.
  # These are the "plain-typed string/date columns" the spec names.
  defp plain_string_or_date_attributes(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(fn attr ->
      type = resolve_type(attr.type)
      type in [Ash.Type.String, Ash.Type.CiString, Ash.Type.Date] or
        attr.type in [:string, :ci_string, :date]
    end)
    # Exclude the injected id/org_id/timestamps (they are non-PII by nature and
    # already in the baseline if the resource existed before). We do not
    # explicitly exclude them — the baseline check handles pre-existing columns;
    # name-pattern check does not match "id", "org_id", "inserted_at", or
    # "updated_at", so they never flag. Keeping the filter simple is safer.
  end

  # Compute the set of logical attribute names that are vault-routed.
  defp vault_routed_names(resource) do
    resource
    |> PiiInfo.pii_attributes()
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  # Build a set of physical column names cleared by valid non_pii! overrides
  # (distinct reviewer enforced).
  defp non_pii_cleared_set(registry_entries, table_name) do
    registry_entries
    |> Enum.filter(fn e ->
      e.table_name == table_name and e.cleared_by != e.reviewed_by
    end)
    |> Enum.map(& &1.column_name)
    |> MapSet.new()
  end

  # Compute the flag reasons for an attribute (could be empty → no flag).
  defp flag_reasons(attr) do
    name_reasons =
      if pii_name?(attr.name) do
        ["identifier-shape name: :#{attr.name} matches a PII pattern"]
      else
        []
      end

    value_reasons = value_shape_reasons(attr)

    name_reasons ++ value_reasons
  end

  # Inspect default values / constraints for PII-shaped sample values.
  defp value_shape_reasons(attr) do
    candidate_values = extract_sample_values(attr)

    Enum.flat_map(candidate_values, fn val ->
      case pii_shaped_value?(val) do
        {true, shape} ->
          ["PII-shaped #{shape} sample value: #{inspect(String.slice(val, 0, 40))}"]

        _ ->
          []
      end
    end)
  end

  # Extract string values from an attribute's default and constraints that could
  # be sample/seed data.
  defp extract_sample_values(attr) do
    default_vals =
      case attr.default do
        v when is_binary(v) -> [v]
        _ -> []
      end

    constraint_vals = extract_constraint_values(attr.constraints)

    default_vals ++ constraint_vals
  end

  # Pull candidate string values from Ash constraint lists.
  defp extract_constraint_values(nil), do: []
  defp extract_constraint_values([]), do: []

  defp extract_constraint_values(constraints) when is_list(constraints) do
    constraints
    |> Enum.flat_map(fn
      {_key, v} when is_binary(v) -> [v]
      {_key, list} when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end)
  end

  defp extract_constraint_values(_), do: []

  # Resolve a short Ash type atom to the full module.
  defp resolve_type(type) when is_atom(type) do
    try do
      Ash.Type.get_type(type)
    rescue
      _ -> type
    end
  end

  defp resolve_type(type), do: type

  # Extract (table_name, column_name) pairs from the schema.dict.json structure.
  defp extract_baseline_pairs(%{"tables" => tables}) when is_list(tables) do
    Enum.flat_map(tables, fn
      %{"table_name" => tbl, "fields" => fields} when is_list(fields) ->
        Enum.map(fields, fn
          %{"column_name" => col} -> {tbl, col}
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp extract_baseline_pairs(_), do: MapSet.new()
end
