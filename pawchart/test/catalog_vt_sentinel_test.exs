defmodule Pawchart.CatalogVtSentinelTest do
  @moduledoc """
  ADR-043 §8a: no string in pawchart's AI catalogue (`Samen.AI.Catalog.schema/0`) carries the vault-token sentinel
  `vt_`. The AI chokepoint refuses any metadata string containing it, so one such string, whether a description, a
  label, a synonym, a unit, an allowed value or a table, column or logical name, would refuse every auto-grounded
  completion and the MCP browse. The compile-time meaning check refuses the authored channels; this walks the whole
  catalogue, including the ones it cannot see (names) and any facet added later.
  """
  use ExUnit.Case, async: true

  alias Samen.AI.Catalog
  alias Samen.AI.VtSentinel

  test "no string anywhere in pawchart's catalogue carries the vault-token sentinel" do
    leaves = VtSentinel.leaves(Catalog.schema())

    # anti-tautology: the walk reaches every channel, allowed values included
    assert length(leaves) > 5_000
    assert Enum.any?(leaves, fn {path, _} -> "allowed_values" in path end)

    offenders = for {path, text} <- leaves, VtSentinel.in_string?(text), do: {path, text}
    assert offenders == [], "strings the AI chokepoint would refuse: #{inspect(Enum.take(offenders, 5))}"
  end
end
