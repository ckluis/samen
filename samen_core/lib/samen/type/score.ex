defmodule Samen.Type.Score do
  @moduledoc """
  `Samen.Type.Score` — H2's score scalar (ADR-036 D2; WS-H spec §H2), a
  bounded, range-validating `Ash.Type` for an arbitrary-scale numeric score
  (a health score, an NPS-style rating, a lead score).

  ## Storage shape

  `storage_type/1` is `:decimal`. The canonical value is a `Decimal.t()`
  clamped to `[min, max]` (default `0..100`) and rounded to `decimals` places
  (default `0` — scores are whole numbers by default, unlike `Percent`).

  ## Constraints (ADR-036 §3 H2 table)

    * `:min`      — default `0`
    * `:max`      — default `100`
    * `:decimals` — default `0`

  `cast_input/2` range/format-validates and FAILS `:error` on violation — no
  silent clamping.

  ## PII posture — non-PII, cleared (ADR-036 D2; ADR-034 gate)

  A score is categorically **not** PII. This module self-classifies `:non_pii`
  (`samen_pii_class/0`), and `samen_core` SHIPS the two-distinct-party
  `Samen.NonPii.TypeClearance` entry that governs it — the classification
  oracle honors the self-class foundry-wide, in every host application, with
  no per-host config required.
  """
  use Ash.Type

  @default_min Decimal.new(0)
  @default_max Decimal.new(100)
  @default_decimals 0

  @doc "Self-classification for `Samen.Pii.Classification`: a score is non-PII (ADR-036 D2)."
  def samen_pii_class, do: :non_pii

  @impl true
  def storage_type(_constraints), do: :decimal

  @impl true
  def constraints do
    [
      min: [type: :any, default: @default_min, doc: "Minimum score value (inclusive)."],
      max: [type: :any, default: @default_max, doc: "Maximum score value (inclusive)."],
      decimals: [
        type: :non_neg_integer,
        default: @default_decimals,
        doc: "Rounding scale (decimal places)."
      ]
    ]
  end

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(%Decimal{} = value, constraints), do: validate_range(value, constraints)

  def cast_input(value, constraints) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> validate_range(decimal, constraints)
      _ -> :error
    end
  end

  def cast_input(value, constraints) when is_integer(value) do
    validate_range(Decimal.new(value), constraints)
  end

  def cast_input(value, constraints) when is_float(value) do
    validate_range(Decimal.from_float(value), constraints)
  end

  def cast_input(_other, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(%Decimal{} = value, _constraints), do: {:ok, value}

  def cast_stored(value, _constraints) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  def cast_stored(_other, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(%Decimal{} = value, _constraints), do: {:ok, value}
  def dump_to_native(_other, _constraints), do: :error

  defp validate_range(%Decimal{} = decimal, constraints) do
    min = Keyword.get(constraints, :min, @default_min) |> to_decimal()
    max = Keyword.get(constraints, :max, @default_max) |> to_decimal()
    decimals = Keyword.get(constraints, :decimals, @default_decimals)

    rounded = Decimal.round(decimal, decimals)

    cond do
      Decimal.compare(rounded, min) == :lt -> :error
      Decimal.compare(rounded, max) == :gt -> :error
      true -> {:ok, rounded}
    end
  end

  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(v) when is_integer(v), do: Decimal.new(v)
  defp to_decimal(v) when is_float(v), do: Decimal.from_float(v)
  defp to_decimal(v) when is_binary(v), do: Decimal.new(v)
end
