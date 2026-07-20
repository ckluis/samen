defmodule Samen.Web.CsvPropertyTest do
  @moduledoc """
  WS-F4 QA property — the hand-rolled RFC-4180 `Samen.Web.Csv.serialize/1` +
  `parse/1` round-trip, and the F1.4 formula-injection neutralization, proven over
  arbitrary generated input.

  Two invariants:

    * **RFC-4180 round-trip (through neutralization)** — for arbitrary rows of arbitrary
      string cells (embedded commas, quotes, CRLF/LF, unicode), `parse(serialize(rows))`
      returns each cell equal to its NEUTRALIZED form. Because the serializer defangs a
      live-formula lead before quoting, the fixed point of the round-trip is the
      neutralized value — so the property is stated against a local neutralization oracle
      that mirrors the module (any drift between the oracle and the code FAILS the test).
    * **Formula-injection (F1.4 / OWASP "CSV Injection")** — the round-tripped cell NEVER
      starts with a spreadsheet formula-lead character (`= + - @` / TAB / CR), UNLESS the
      cell is a plain number (a legitimate negative amount stays numeric). This is the
      load-bearing guarantee: an exported cell cannot smuggle a live formula.

  Pattern reference: `samen_core/test/abbrev_property_test.exs` (StreamData over the real
  production function, not a re-implementation).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Samen.Web.Csv

  # The module's formula-lead set (Samen.Web.Csv @formula_leads) — kept in sync here as
  # the oracle; a divergence surfaces as a property failure.
  @formula_leads [?=, ?+, ?-, ?@, ?\t, ?\r]

  # Oracle mirror of Samen.Web.Csv.neutralize_formula/1 (private). A cell whose first BYTE
  # is a formula lead is prefixed with a single quote UNLESS it is a plain number.
  defp neutralize(<<lead, _::binary>> = value) when lead in @formula_leads do
    if numeric?(value), do: value, else: "'" <> value
  end

  defp neutralize(value), do: value

  defp numeric?(value), do: match?({_parsed, ""}, Float.parse(value))

  defp starts_with_formula_lead?(<<lead, _::binary>>), do: lead in @formula_leads
  defp starts_with_formula_lead?(_), do: false

  # A row is a NON-EMPTY list of arbitrary string cells (empty-list rows are not a CSV
  # concept — a blank line is a single empty cell, tested explicitly below).
  defp row_gen do
    StreamData.list_of(StreamData.string(:printable, max_length: 24), min_length: 1, max_length: 6)
  end

  # A cell biased toward a formula lead so the neutralization path is exercised often.
  defp formula_cell_gen do
    StreamData.one_of([
      StreamData.string(:printable, max_length: 24),
      StreamData.bind(
        StreamData.member_of(["=", "+", "-", "@", "\t", "\r"]),
        fn lead ->
          StreamData.map(StreamData.string(:printable, max_length: 20), &(lead <> &1))
        end
      )
    ])
  end

  property "RFC-4180 round-trip: parse(serialize(rows)) == neutralized(rows)" do
    check all(rows <- StreamData.list_of(row_gen(), min_length: 1, max_length: 6), max_runs: 200) do
      expected = Enum.map(rows, fn row -> Enum.map(row, &neutralize/1) end)
      assert Csv.parse(Csv.serialize(rows)) == expected
    end
  end

  property "formula-injection: a round-tripped cell never starts with a formula lead (unless numeric)" do
    check all(cell <- formula_cell_gen(), max_runs: 200) do
      [[round_tripped]] = Csv.parse(Csv.serialize([[cell]]))

      assert numeric?(cell) or not starts_with_formula_lead?(round_tripped),
             "cell #{inspect(cell)} round-tripped to #{inspect(round_tripped)} — a live formula lead survived"
    end
  end

  # -- explicit boundary examples (belt-and-suspenders on the property oracle) --

  test "a live formula export cell is defanged to literal text" do
    assert [["'=1+1"]] = Csv.parse(Csv.serialize([["=1+1"]]))
    assert [["'@SUM(A1:A9)"]] = Csv.parse(Csv.serialize([["@SUM(A1:A9)"]]))
    assert [["'-2+3+cmd|'/C calc'!A1"]] = Csv.parse(Csv.serialize([["-2+3+cmd|'/C calc'!A1"]]))
  end

  test "a legitimate negative number stays numeric (not defanged)" do
    assert [["-5"]] = Csv.parse(Csv.serialize([["-5"]]))
    assert [["-3.14"]] = Csv.parse(Csv.serialize([["-3.14"]]))
  end

  test "embedded commas / quotes / newlines round-trip exactly (safe leads)" do
    row = ["a,b", "he said \"hi\"", "line1\nline2", "plain"]
    assert [^row] = Csv.parse(Csv.serialize([row]))
  end

  test "a blank line is a single empty cell" do
    assert [[""]] = Csv.parse(Csv.serialize([[""]]))
  end
end
