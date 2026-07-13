defmodule Samen.FeatureFlags.TargetRule do
  @moduledoc """
  A single targeting rule for a feature flag (ADR-020 §2 decision 3, design G6 §3.2
  step 2). Rules key ONLY off governed, NON-PII attributes — org id, plan, tier,
  stage — NEVER name/email/phone. That non-PII guarantee is enforced at flag-WRITE
  time (`Samen.FeatureFlags.NonPiiTargeting`, RP-F3), not at read: a `TargetRule`
  that reaches `evaluate/2` has already passed the write-time refusal, so the engine
  never receives a PII subject key.

  ## Shape (bounded jsonb on the `pff` resource)

      %{"attribute" => "plan", "op" => "in", "values" => ["pro", "enterprise"],
        "then" => "on"}

    * `attribute` — the subject-scope key to test. Validated non-PII at write.
    * `op` — `"eq"` | `"in"` | `"neq"` | `"not_in"`.
    * `values` — a bounded list of scalar values to compare against.
    * `then` — the outcome when the rule matches: `"on"` | `"off"` | `"deny"` |
      `"allow"` | a variant name string. `"deny"`/`"allow"` map to the explicit
      deny/allow precedence tiers; a bare `"on"`/`"off"` is `:targeted`.

  First match wins. `parse/1` is tolerant — a malformed rule is dropped (the flag
  degrades to its rollout/default, never crashes evaluation).
  """

  alias Samen.FeatureFlags.Decision

  @type t :: %__MODULE__{
          attribute: String.t(),
          op: :eq | :in | :neq | :not_in,
          values: [term()],
          then: :on | :off | :deny | :allow | {:variant, atom()}
        }

  @enforce_keys [:attribute, :op, :values, :then]
  defstruct [:attribute, :op, :values, :then]

  @ops %{"eq" => :eq, "in" => :in, "neq" => :neq, "not_in" => :not_in}

  @doc """
  Parse a list of raw jsonb rule maps into `%TargetRule{}` structs, dropping any
  that are structurally invalid. Never raises.
  """
  @spec parse(list() | nil) :: [t()]
  def parse(nil), do: []

  def parse(rules) when is_list(rules) do
    rules
    |> Enum.map(&parse_one/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(_), do: []

  defp parse_one(%{} = raw) do
    attribute = raw["attribute"] || raw[:attribute]
    op_raw = raw["op"] || raw[:op] || "eq"
    values = raw["values"] || raw[:values] || []
    then_raw = raw["then"] || raw[:then] || "on"

    with true <- is_binary(attribute) and attribute != "",
         op when not is_nil(op) <- Map.get(@ops, to_string(op_raw)),
         true <- is_list(values),
         then_val when not is_nil(then_val) <- parse_then(then_raw) do
      %__MODULE__{attribute: attribute, op: op, values: values, then: then_val}
    else
      _ -> nil
    end
  end

  defp parse_one(_), do: nil

  defp parse_then("on"), do: :on
  defp parse_then("off"), do: :off
  defp parse_then("deny"), do: :deny
  defp parse_then("allow"), do: :allow
  defp parse_then(name) when is_binary(name) and name != "", do: {:variant, safe_atom(name)}
  defp parse_then(_), do: nil

  # Only ever converts a config-authored variant name to an atom; bounded by the
  # write-time validation. Falls back to an existing atom to avoid atom-table
  # growth from unbounded input.
  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> String.to_atom(name)
  end

  @doc """
  Return the first rule whose `attribute`/`op`/`values` match the subject scope,
  or `nil`. `subject` is a map of non-PII keys (e.g. `%{org_id: ..., plan: "pro"}`).
  """
  @spec first_match([t()], map()) :: t() | nil
  def first_match(rules, subject) when is_list(rules) and is_map(subject) do
    Enum.find(rules, fn rule -> matches?(rule, subject) end)
  end

  @doc "Does a single rule match the subject scope?"
  @spec matches?(t(), map()) :: boolean()
  def matches?(%__MODULE__{attribute: attr, op: op, values: values}, subject) do
    actual = fetch(subject, attr)
    apply_op(op, actual, values)
  end

  # Subject keys may be atoms or strings; compare by string form of both key and value.
  defp fetch(subject, attr) do
    cond do
      Map.has_key?(subject, attr) -> Map.get(subject, attr)
      Map.has_key?(subject, safe_key(attr)) -> Map.get(subject, safe_key(attr))
      true -> nil
    end
  end

  defp safe_key(attr) do
    String.to_existing_atom(attr)
  rescue
    ArgumentError -> attr
  end

  defp apply_op(_op, nil, _values), do: false
  defp apply_op(:eq, actual, [v | _]), do: eq?(actual, v)
  defp apply_op(:eq, _actual, []), do: false
  defp apply_op(:neq, actual, [v | _]), do: not eq?(actual, v)
  defp apply_op(:neq, _actual, []), do: true
  defp apply_op(:in, actual, values), do: Enum.any?(values, &eq?(actual, &1))
  defp apply_op(:not_in, actual, values), do: not Enum.any?(values, &eq?(actual, &1))

  # Loose equality across atom/string boundaries so config-authored string values
  # match atom subject values (`"pro"` matches `:pro`).
  defp eq?(a, b) when a == b, do: true
  defp eq?(a, b), do: to_string(a) == to_string(b)

  @doc """
  Convert a matched rule's `then` into a `Decision`, given the deterministic
  subject bucket function for variant assignment (unused for plain on/off).
  """
  @spec decide(t()) :: Decision.t()
  def decide(%__MODULE__{then: :on}), do: %Decision{on: true, reason: :targeted}
  def decide(%__MODULE__{then: :off}), do: %Decision{on: false, reason: :targeted}
  def decide(%__MODULE__{then: :allow}), do: %Decision{on: true, reason: :allow}
  def decide(%__MODULE__{then: :deny}), do: %Decision{on: false, reason: :deny}

  def decide(%__MODULE__{then: {:variant, name}}),
    do: %Decision{on: true, variant: name, reason: :targeted}
end
