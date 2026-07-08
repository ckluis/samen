defmodule Samen.AggregateSuppressedTest do
  @moduledoc """
  T4.5 — `%Samen.Aggregate.Suppressed{}` renders as a fail-closed sentinel in every
  serialization path (mirrors the `%Masked{}` contract), and NEVER carries the withheld
  value. A serialization path that forgot about suppression cannot emit the value —
  it structurally isn't in the struct.
  """
  use ExUnit.Case, async: true

  alias Samen.Aggregate.Suppressed

  test "constructors carry the reason + params but NEVER the underlying value" do
    k = Suppressed.k_anonymity(5, 1)
    assert k.reason == :k_anonymity
    assert k.k == 5
    assert k.observed == 1

    l = Suppressed.l_diversity(2, 1)
    assert l.reason == :l_diversity
    assert l.l == 2
    assert l.observed == 1

    # T6.6: the query-budget suppression reason (the enforcing cross-query budget).
    b = Suppressed.query_budget(100, 101)
    assert b.reason == :query_budget
    assert b.limit == 100
    assert b.observed == 101
    # NEVER carries the withheld value — only the reason + budget params.
    refute Map.has_key?(Map.from_struct(b), :value)
  end

  test "the query-budget sentinel renders as ⊘ / a marker in every path, no value leaked" do
    b = Suppressed.query_budget(100, 101)
    assert to_string(b) == "⊘"
    assert inspect(b) =~ "query_budget"

    json = Jason.encode!(%{mrr_cents: b})
    assert Jason.decode!(json) == %{"mrr_cents" => %{"suppressed" => true, "reason" => "query_budget"}}
  end

  test "String.Chars renders the glyph, not a value" do
    assert to_string(Suppressed.k_anonymity(5, 1)) == "⊘"
    assert "cell: ⊘" == "cell: #{Suppressed.l_diversity(2, 1)}"
  end

  test "Inspect surfaces the reason + glyph but no value" do
    s = inspect(Suppressed.k_anonymity(5, 1))
    assert s =~ "Suppressed"
    assert s =~ "k_anonymity"
    assert s =~ "⊘"
    refute s =~ "1"
  end

  test "Jason.Encoder emits a machine-readable suppression marker, not the value" do
    json = Jason.encode!(%{depth: Suppressed.l_diversity(2, 1)})
    decoded = Jason.decode!(json)
    assert decoded["depth"] == %{"suppressed" => true, "reason" => "l_diversity"}
    # No numeric value leaked anywhere in the JSON.
    refute json =~ ~r/"depth":\s*\d/
  end

  test "suppressed?/1 discriminates the sentinel from real values" do
    assert Suppressed.suppressed?(Suppressed.k_anonymity(5, 1))
    refute Suppressed.suppressed?(10_000)
    refute Suppressed.suppressed?(nil)
    refute Suppressed.suppressed?(%{})
  end
end
