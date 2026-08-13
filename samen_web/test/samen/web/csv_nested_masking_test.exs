defmodule Samen.Web.CsvNestedMaskingTest do
  @moduledoc """
  D7 / ADR-046 §4.6 — a `%Samen.Masked{}` nested INSIDE a container cell (a
  `:map`/list column value) must serialize as its MASKED representation (`••••`),
  NEVER unwrapped to its `vt_*` vault token.

  `Samen.Web.Csv.compact/1` unwraps any struct via `Map.from_struct/1` before
  JSON-encoding a container cell; without the guard clause a nested `%Masked{}`
  would serialize as `{"token":"vt_…","label":…}`, defeating the module's own
  "NEVER a `vt_*` token" guarantee for any nested occurrence.

  MaskingCase discipline (INV-1 — this only makes CSV strictly SAFER):

    * **RED** — a container-nested masked value serializes to `••••`; no `vt_*`
      token anywhere in the cell.
    * **ANTI-TAUTOLOGY (plane-flip → clear)** — the SAME container position holding
      the REVEALED plaintext (what the tenant plane would carry) serializes in the
      CLEAR, and does NOT collapse to the mask. So the masked cell is the value's
      masked-ness, not a blanket "serialize everything as ••••".
    * **SABOTAGE twin (refutability)** — a modeled unwrapped-struct serialization
      (exactly what reverting the `compact(%Masked{})` clause produces) IS caught
      by the `vt_` leak scan the RED assertions rely on.

  The serialization boundary is exercised through `Csv.render_cell/1` — the same
  private `cell/1`/`compact/1` path `export_rows/8` runs every export cell through.
  """
  use ExUnit.Case, async: true
  use Samen.MaskingCase

  alias Samen.Masked
  alias Samen.Web.Csv

  @token "vt_deadbeefcafe0123"

  describe "RED — a container-nested %Masked{} serializes as •••• (no vt_ token)" do
    test "nested inside a MAP" do
      cell = Csv.render_cell(%{"secret" => Masked.new(@token, :email), "public" => "keep"})

      # Mask present, the vault token absent, no vt_* anywhere — and the non-PII
      # sibling key rides along untouched (masking is per-value, not per-cell).
      assert_masked_dom!(cell, [@token])
      assert cell =~ "keep"
      refute cell =~ "vt_"
    end

    test "nested inside a LIST" do
      cell = Csv.render_cell([Masked.new(@token, :email), "keep"])

      assert_masked_dom!(cell, [@token])
      assert cell =~ "keep"
      refute cell =~ "vt_"
    end

    test "nested DEEPLY (map inside a list inside a map)" do
      cell = Csv.render_cell(%{"outer" => [%{"inner" => Masked.new(@token, :phone)}]})

      assert_masked_dom!(cell, [@token])
      refute cell =~ "vt_"
    end
  end

  describe "ANTI-TAUTOLOGY — the same container carrying the REVEALED value goes CLEAR" do
    test "plane-flip: a plaintext in the same position serializes in the clear, not masked" do
      # The tenant plane would carry the revealed value here (not a %Masked{}).
      cell = Csv.render_cell(%{"secret" => "revealed-plain-xyz", "public" => "keep"})

      assert cell =~ "revealed-plain-xyz", "clear content must serialize in the clear"
      refute cell =~ Samen.MaskingCase.mask(),
             "a clear container value must NOT collapse to the mask (proves masking is per-value)"
    end
  end

  describe "SABOTAGE twin — the vt_ leak scan is refutable" do
    test "a modeled unwrapped-struct serialization (the reverted-clause output) IS caught" do
      # Exactly what `compact/1` would emit WITHOUT the %Masked{} guard clause:
      # the struct unwrapped to its raw fields, leaking the vault token.
      leaked = Jason.encode!(%{"secret" => %{"token" => @token, "label" => "email"}})

      assert_leak_detected!(leaked, "vt_")
    end
  end
end
