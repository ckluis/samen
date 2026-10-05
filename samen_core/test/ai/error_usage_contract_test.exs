defmodule Samen.AI.ErrorUsageContractTest do
  @moduledoc """
  Issue #11 — the WRITTEN contract for a usage-carrying failure, read out of the compiled
  BEAM. No dialyzer runs anywhere in this repo, so nothing else would notice if the
  `{:error, reason, usage}` return were dropped from a `@callback` or `@spec` again: the
  code would keep working while the contract every adapter author reads went back to
  saying it cannot happen. This is the test that notices.

  Three declarations must admit the three-element error, each with a usage map naming all
  three token buckets — `:input_tokens`, `:cached_input_tokens` (issue #74) and
  `:output_tokens`:

    * `Samen.AI.Provider.complete/2` — the `@callback` an adapter implements;
    * `Samen.AI.complete/4` — the public entry point (`error_usage: true` callers);
    * `Samen.AI.Chokepoint.complete/5` — the one provider-invocation site.
  """
  use ExUnit.Case, async: true

  # Every `{:error, _, usage}` tuple type in the quoted spec whose third element is a map
  # type, as the set of key atoms that map type names.
  defp usage_tuples(quoted) do
    {_, found} =
      Macro.prewalk(quoted, [], fn
        {:{}, _, [:error, _reason, {:%{}, _, fields}]} = node, acc ->
          {node, [MapSet.new(fields, &field_key/1) | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp field_key({{:optional, _, [key]}, _type}), do: key
  defp field_key({{:required, _, [key]}, _type}), do: key
  defp field_key({key, _type}) when is_atom(key), do: key
  defp field_key(_other), do: nil

  defp callback(module, name, arity) do
    {:ok, callbacks} = Code.Typespec.fetch_callbacks(module)

    for {{^name, ^arity}, specs} <- callbacks,
        spec <- specs,
        do: Code.Typespec.spec_to_quoted(name, spec)
  end

  defp spec(module, name, arity) do
    {:ok, specs} = Code.Typespec.fetch_specs(module)
    for {{^name, ^arity}, list} <- specs, s <- list, do: Code.Typespec.spec_to_quoted(name, s)
  end

  defp assert_admits_usage!(quoted, label) do
    assert quoted != [], "#{label}: no spec found — the enumeration is empty, not a pass"

    keys = quoted |> Enum.flat_map(&usage_tuples/1)

    # Issue #74: all three buckets, the cached-input one included.
    buckets = MapSet.new([:input_tokens, :cached_input_tokens, :output_tokens])

    assert Enum.any?(keys, &MapSet.subset?(buckets, &1)),
           "#{label} no longer admits {:error, reason, %{input_tokens: _, cached_input_tokens: _, output_tokens: _}}: " <>
             Enum.map_join(quoted, "\n", &Macro.to_string/1)
  end

  test "Samen.AI.Provider's complete/2 @callback admits a usage-carrying failure" do
    assert_admits_usage!(
      callback(Samen.AI.Provider, :complete, 2),
      "Samen.AI.Provider.complete/2 @callback"
    )
  end

  test "Samen.AI.complete/4's @spec admits it" do
    assert_admits_usage!(spec(Samen.AI, :complete, 4), "Samen.AI.complete/4 @spec")
  end

  test "Samen.AI.Chokepoint.complete/5's @spec admits it" do
    assert_admits_usage!(
      spec(Samen.AI.Chokepoint, :complete, 5),
      "Samen.AI.Chokepoint.complete/5 @spec"
    )
  end

  test "positive control: the walker finds nothing in a spec that has no usage tuple" do
    # embed/2 never carries usage — the walker must answer [] there, or the asserts above
    # would pass on anything.
    assert callback(Samen.AI.Provider, :embed, 2) != []
    assert Enum.flat_map(callback(Samen.AI.Provider, :embed, 2), &usage_tuples/1) == []
  end
end
