defmodule Samen.Automation.Condition do
  @moduledoc """
  The E1 condition evaluator (ADR-039 §4.4) — the `Samen.FeatureFlags.TargetRule`
  precedent, generalized from first-match routing to an **AND-gate**.

  A workflow's `conditions` are a bounded jsonb list. ALL of them must match for the
  workflow's actions to run (these are gates, not routers — no first-match-wins).
  Shape of one condition:

      %{"attribute" => "priority", "op" => "gte", "values" => ["high"]}

  ## Op set (ADR-039 §4.4)

  `eq | neq | in | not_in | gt | gte | lt | lte | is_nil | not_nil | changed`.
  `changed` tests membership in the envelope's `changed` attribute-name list (so
  "when status changes" is expressible); every other op compares the subject's
  attribute value against `values`.

  ## Tolerant parse, but fail-CLOSED on drop (the automation-safety divergence)

  Like `TargetRule.parse/1`, `parse/1` never raises and DROPS a structurally-invalid
  condition. But automation diverges from flag targeting in the consequence: a flag
  degrades to its rollout/default when a rule is dropped, whereas an **automation must
  never fire on fewer gates than the tenant authored**. So callers compare
  `parse_count/1` against the stored length via `valid?/2`: if the parsed list is
  shorter than the stored list the run is recorded `:skipped / :invalid_conditions`
  and the actions do NOT run. `parse/1` is the tolerant reader; `valid?/2` is the
  fire-gate guard.

  ## PII is structurally out of reach here

  `matches?/2` only ever sees a subject map built from **condition-eligible**
  attributes (ADR-039 §4.4 oracle — `Samen.Automation.NonPiiPredicates`). A vault
  field is refused at WRITE time (it can never appear in a stored condition) and is
  excluded from the subject map at read time (`Samen.Automation.RunWorker`), so a
  vaulted value cannot reach this evaluator by construction. Nothing here needs to
  know about masking — the boundary upstream guarantees it.
  """

  @type condition :: %{
          attribute: String.t(),
          op: atom(),
          values: [term()]
        }

  @ops ~w(eq neq in not_in gt gte lt lte is_nil not_nil changed)a
  @ops_map Map.new(@ops, fn op -> {Atom.to_string(op), op} end)

  @doc """
  Parse a raw jsonb condition list into normalized condition maps, dropping any that
  are structurally invalid. Never raises. Order is preserved.
  """
  @spec parse(list() | nil) :: [condition()]
  def parse(nil), do: []

  def parse(list) when is_list(list) do
    list
    |> Enum.map(&parse_one/1)
    |> Enum.reject(&is_nil/1)
  end

  def parse(_), do: []

  defp parse_one(%{} = raw) do
    attribute = raw["attribute"] || raw[:attribute]
    op_raw = raw["op"] || raw[:op] || "eq"
    values = raw["values"] || raw[:values] || []

    with true <- is_binary(attribute) and attribute != "",
         op when not is_nil(op) <- Map.get(@ops_map, to_string(op_raw)),
         true <- is_list(values) do
      %{attribute: attribute, op: op, values: values}
    else
      _ -> nil
    end
  end

  defp parse_one(_), do: nil

  @doc "How many raw conditions parse cleanly (for the `:invalid_conditions` gate)."
  @spec parse_count(list() | nil) :: non_neg_integer()
  def parse_count(list), do: length(parse(list))

  @doc """
  Are the stored conditions ALL well-formed? A parsed list shorter than the stored
  list means a condition was dropped — the run must NOT fire (ADR-039 §4.4). Returns
  `false` for that case; `true` when every stored condition parsed.
  """
  @spec valid?(list() | nil) :: boolean()
  def valid?(nil), do: true
  def valid?(list) when is_list(list), do: parse_count(list) == length(list)
  def valid?(_), do: false

  @doc """
  Evaluate the full AND-gate. Returns `true` iff EVERY parsed condition matches the
  subject. An empty condition list matches (a workflow with no conditions fires on
  every trigger event, subject to the trigger itself). Callers MUST have already
  gated on `valid?/1` — this function evaluates only the parsed conditions.

  `subject` is a map of **condition-eligible** attributes (string or atom keys).
  `changed` is the envelope's list of changed attribute names (for the `changed` op).
  """
  @spec all_match?([condition()], map(), [String.t()]) :: boolean()
  def all_match?(conditions, subject, changed \\ [])

  def all_match?([], _subject, _changed), do: true

  def all_match?(conditions, subject, changed)
      when is_list(conditions) and is_map(subject) do
    Enum.all?(conditions, &matches?(&1, subject, changed))
  end

  @doc "Does a single parsed condition match the subject?"
  @spec matches?(condition(), map(), [String.t()]) :: boolean()
  def matches?(condition, subject, changed \\ [])

  def matches?(%{op: :changed, attribute: attr}, _subject, changed) do
    attr in Enum.map(List.wrap(changed), &to_string/1)
  end

  def matches?(%{op: op, attribute: attr, values: values}, subject, _changed) do
    actual = fetch(subject, attr)
    apply_op(op, actual, values)
  end

  # Subject keys may be atoms or strings.
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

  defp apply_op(:is_nil, actual, _values), do: is_nil(actual)
  defp apply_op(:not_nil, actual, _values), do: not is_nil(actual)
  defp apply_op(_op, nil, _values), do: false
  defp apply_op(:eq, actual, [v | _]), do: eq?(actual, v)
  defp apply_op(:eq, _actual, []), do: false
  defp apply_op(:neq, actual, [v | _]), do: not eq?(actual, v)
  defp apply_op(:neq, _actual, []), do: true
  defp apply_op(:in, actual, values), do: Enum.any?(values, &eq?(actual, &1))
  defp apply_op(:not_in, actual, values), do: not Enum.any?(values, &eq?(actual, &1))
  defp apply_op(:gt, actual, [v | _]), do: compare(actual, v) == :gt
  defp apply_op(:gte, actual, [v | _]), do: compare(actual, v) in [:gt, :eq]
  defp apply_op(:lt, actual, [v | _]), do: compare(actual, v) == :lt
  defp apply_op(:lte, actual, [v | _]), do: compare(actual, v) in [:lt, :eq]
  defp apply_op(op, _actual, []) when op in [:gt, :gte, :lt, :lte], do: false

  # Loose equality across atom/string boundaries so a config-authored string value
  # ("high") matches an atom subject value (:high). Mirrors TargetRule.eq?/2.
  defp eq?(a, b) when a == b, do: true
  defp eq?(a, b), do: to_string(a) == to_string(b)

  # Ordered comparison for gt/gte/lt/lte. Numbers compare numerically; DateTimes via
  # DateTime.compare; everything else falls back to a total string comparison (which
  # covers ordinal enums authored as strings and ISO8601 timestamps). Returns
  # `:gt | :eq | :lt`.
  defp compare(a, b) when is_number(a) and is_number(b) do
    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  defp compare(%DateTime{} = a, b) when is_binary(b) do
    case DateTime.from_iso8601(b) do
      {:ok, bt, _} -> DateTime.compare(a, bt)
      _ -> :lt
    end
  end

  defp compare(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)

  defp compare(a, b) when is_number(a) and is_binary(b) do
    case parse_number(b) do
      {:ok, bn} -> compare(a, bn)
      :error -> compare(to_string(a), b)
    end
  end

  defp compare(a, b) do
    a = to_string(a)
    b = to_string(b)

    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  defp parse_number(str) do
    case Integer.parse(str) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(str) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end
    end
  end
end
