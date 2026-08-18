defmodule Samen.Automation.NonPiiPredicates do
  @moduledoc """
  Write-time refusal that a Workflow's `conditions` and `actions` key ONLY off
  **condition-eligible** attributes of the target resource (ADR-039 §4.4 / §5.2 /
  c13; INV-1). This is the automation analogue of `Samen.FeatureFlags.NonPiiTargeting`
  (the RP-F3 precedent), generalized from flags' name-based allowlist to the ONE
  shared eligibility oracle.

  ## The one oracle, three consumers

  Eligibility is NOT a second classifier. An attribute is condition-eligible iff it
  projects through `Samen.Cdc.Projection` as a **non-token, non-plaintext kind** — i.e.
  a structural-safe scalar (bounded id / enum / timestamp / number / boolean) OR a
  freeform column carrying a two-reviewer `non_pii!` clearance (ADR-015/ADR-034). A
  vault-routed column classifies `:token` and a plaintext-PII column classifies
  `:plaintext_pii` — both REFUSED. CDC projection, flag targeting, and automation
  predicates now share one place where "non-PII-keyable" is defined and verified
  (ADR-039 §14.3); no second classification can drift.

  So a `pii_*` / vault-routed attribute is **structurally unreferenceable** in any
  workflow condition or action interpolation — refused at the earliest boundary (the
  Workflow WRITE), long before any value could reach the evaluator, an interpolation,
  or a webhook payload (INV-1). This is the load-bearing refusal T39's red-path test
  and the §11 sabotage flip.

  ## Two write-time gates

    1. **Condition attributes** — every `conditions[*].attribute` (for every op,
       including `changed`) must be eligible.
    2. **Action interpolations** — every `{{subject.<attr>}}` reference inside an
       action config must reference an eligible attribute (forward-compat with T40's
       action library; T39's `notify` config carries none, so this is vacuous today
       but the gate is live).

  Both default-DENY: an attribute that does not resolve to an eligible attribute of
  the target resource (unknown, vaulted, or plaintext) is refused.
  """
  use Ash.Resource.Validation

  alias Samen.Cdc.Projection

  @refused_kinds [:token, :plaintext_pii]
  @interp_rx ~r/\{\{\s*subject\.([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/

  @impl true
  def validate(changeset, _opts, _context) do
    resource_key = Ash.Changeset.get_attribute(changeset, :resource_key)
    conditions = Ash.Changeset.get_attribute(changeset, :conditions)
    actions = Ash.Changeset.get_attribute(changeset, :actions)

    case check(conditions, actions, resource_key) do
      :ok ->
        :ok

      {:error, where, attribute, reason} ->
        {:error,
         field: field_for(where),
         message:
           "automation #{where} keyed on #{inspect(attribute)} is refused: #{reason}. " <>
             "Conditions and interpolations may key ONLY off condition-eligible " <>
             "(non-PII, non-vaulted) attributes of the target resource — a vaulted or " <>
             "plaintext-PII field is structurally unreferenceable in a workflow (INV-1)."}
    end
  end

  @doc """
  Pure check used by the validation AND directly by the red-path test. Returns `:ok`
  or `{:error, where, attribute, reason}` on the FIRST refused reference, where
  `where` is `:condition` or `:interpolation`.
  """
  @spec check(term(), term(), term()) ::
          :ok | {:error, :condition | :interpolation, term(), String.t()}
  def check(conditions, actions, resource_key) do
    interps = interpolated_names(actions)
    has_conditions = is_list(conditions) and conditions != []

    # Nothing keys off the subject ⇒ nothing to verify (a schedule/manual workflow with
    # no conditions and no subject interpolations needs no resource_key).
    if not has_conditions and interps == [] do
      :ok
    else
      with {:ok, eligible} <- eligible_names(resource_key),
           :ok <- check_conditions(conditions, eligible) do
        check_interps(interps, eligible)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The eligibility oracle (ADR-039 §4.4) — logical attribute names that project
  # through Samen.Cdc.Projection as a non-token, non-plaintext kind.

  @doc """
  The MapSet of condition-eligible LOGICAL attribute names for a target resource.
  Resolves `resource_key` (the fully-qualified resource module string — the catalog
  identity of the trigger source) to a module, then joins the CDC projection's
  column classification onto logical names. Fail-CLOSED: an unresolvable resource_key
  yields `{:error, ...}` so the write is refused (you cannot verify eligibility
  against a resource you cannot see).
  """
  @spec eligible_names(term()) ::
          {:ok, MapSet.t()} | {:error, :condition, term(), String.t()}
  def eligible_names(resource_key) when is_binary(resource_key) and resource_key != "" do
    case resolve_resource(resource_key) do
      {:ok, resource} ->
        source_to_logical =
          resource
          |> Ash.Resource.Info.attributes()
          |> Map.new(fn a -> {to_string(a.source || a.name), to_string(a.name)} end)

        eligible =
          resource
          |> Projection.classify_columns()
          |> Enum.reject(fn {_col, kind} -> kind in @refused_kinds end)
          |> Enum.map(fn {col, _kind} -> Map.get(source_to_logical, col, col) end)
          |> MapSet.new()

        {:ok, eligible}

      :error ->
        {:error, :condition, resource_key,
         "target resource_key does not resolve to a known resource (default-deny)"}
    end
  rescue
    _ ->
      {:error, :condition, resource_key,
       "target resource could not be classified (default-deny)"}
  end

  def eligible_names(other),
    do: {:error, :condition, other, "resource_key is required and must be a resource module string"}

  defp resolve_resource(str) do
    mod = String.to_existing_atom("Elixir." <> String.trim_leading(str, "Elixir."))

    if Code.ensure_loaded?(mod) and function_exported?(mod, :spark_dsl_config, 0) do
      {:ok, mod}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  # ---------------------------------------------------------------------------
  # Gate 1 — condition attributes.

  defp check_conditions(nil, _eligible), do: :ok
  defp check_conditions([], _eligible), do: :ok

  defp check_conditions(conditions, eligible) when is_list(conditions) do
    Enum.reduce_while(conditions, :ok, fn cond, :ok ->
      attribute = cond_attribute(cond)

      cond do
        not is_binary(attribute) or attribute == "" ->
          {:halt, {:error, :condition, attribute, "missing or non-string attribute"}}

        not MapSet.member?(eligible, attribute) ->
          {:halt,
           {:error, :condition, attribute,
            "not a condition-eligible attribute (vaulted, plaintext-PII, or unknown)"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp check_conditions(other, _eligible),
    do: {:error, :condition, other, "conditions must be a list of condition maps"}

  defp cond_attribute(%{} = c), do: c["attribute"] || c[:attribute]
  defp cond_attribute(_), do: nil

  # ---------------------------------------------------------------------------
  # Gate 2 — action config interpolations ({{subject.attr}}).

  defp check_interps([], _eligible), do: :ok

  defp check_interps(attrs, eligible) when is_list(attrs) do
    Enum.reduce_while(attrs, :ok, fn attr, :ok ->
      if MapSet.member?(eligible, attr) do
        {:cont, :ok}
      else
        {:halt,
         {:error, :interpolation, attr,
          "action interpolates a non-eligible attribute (vaulted, plaintext-PII, or unknown)"}}
      end
    end)
  end

  # All {{subject.<attr>}} references across all action configs.
  defp interpolated_names(actions) when is_list(actions),
    do: actions |> Enum.flat_map(&interpolated_attrs/1) |> Enum.uniq()

  defp interpolated_names(_), do: []

  # Extract every {{subject.<attr>}} reference from all string leaves of an action
  # config map (recursively). Non-string leaves carry no interpolation.
  defp interpolated_attrs(%{} = action) do
    action
    |> Map.values()
    |> Enum.flat_map(&interp_scan/1)
  end

  defp interpolated_attrs(_), do: []

  defp interp_scan(v) when is_binary(v) do
    @interp_rx
    |> Regex.scan(v, capture: :all_but_first)
    |> Enum.map(fn [attr] -> attr end)
  end

  defp interp_scan(v) when is_map(v), do: v |> Map.values() |> Enum.flat_map(&interp_scan/1)
  defp interp_scan(v) when is_list(v), do: Enum.flat_map(v, &interp_scan/1)
  defp interp_scan(_), do: []

  defp field_for(:condition), do: :conditions
  defp field_for(:interpolation), do: :actions
end
