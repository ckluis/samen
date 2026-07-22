defmodule Samen.Type.Money do
  @moduledoc """
  `Samen.Type.Money` — H1's money type (ADR-036 D1; WS-H spec §H1), a **thin samen-
  owned wrapper over `AshMoney.Types.Money`** (ADR-037 §5.2, binding: AshMoney
  ADOPT).

  ## Wrapper, not a reimplementation

  ADR-037 §5.2 already weighed hand-building money arithmetic against adopting
  `ash_money`/`ex_money` and chose ADOPT. The only samen-side decision left is
  *naming*: `Samen.Catalog.fields/1` derives a field's catalog type string via
  `inspect(type) |> String.trim_leading("Ash.Type.")` (`samen_core/lib/samen/catalog.ex`)
  — so the type's own module name IS its catalog/generator/API identity. Wrapping
  with `use Ash.Type.NewType, subtype_of: AshMoney.Types.Money` keeps the catalog
  dump `"Samen.Type.Money"` (never `"AshMoney.Types.Money"`) while every cast/dump/
  constraint/SQL-aggregation behavior delegates unchanged to the package
  (`Ash.Type.NewType` forwards every callback to `subtype_of`).

  ## Storage shape

  Postgres composite `money_with_currency(currency_code varchar, amount numeric)`,
  installed via `AshMoney.AshPostgresExtension` in the host repo's
  `installed_extensions/0`. One physical column. The Ash/Elixir value is an
  `ex_money` `%Money{amount: Decimal.t(), currency: atom()}`.

  ## Cast / dump

  Delegates to `AshMoney.Types.Money.cast_input/2` — accepts `%Money{}`, a
  `{currency, amount}` tuple, or a `%{"amount" => _, "currency" => _}` map (and, via
  ex_money, a `"USD 12.34"`-shaped string through `Money.parse/2` — see `cast_input/2`
  below for the CSV round-trip form). Dumps to the Postgres composite. Two `%Money{}`
  values compare/add/subtract only when their currencies match — ex_money raises
  `Money.ExchangeRateError`/currency-mismatch errors otherwise (proven in
  `money_test.exs`).

  ## PII posture — non-PII, cleared (ADR-036 D1; ADR-034 gate)

  Money is **not PII**. This module self-classifies `:non_pii`
  (`samen_pii_class/0`), and `samen_core` SHIPS the two-distinct-party
  `Samen.NonPii.TypeClearance` entry that governs it (see
  `Samen.NonPii.TypeClearance.clearances/0`) — so the classification oracle
  (`Samen.Pii.Classification.classify/1`) honors the self-class foundry-wide, in
  every host application, with no per-host config required. Drop that clearance
  and the SAME module falls through to the PII default (masked) — the ADR-034
  fail-closed sabotage twin `samen_core/test/pii_type_clearance_test.exs` proves for
  the mechanism generally; `money_test.exs` proves it for this concrete type.

  ## Minor units (cents) helper

  `cents/1` extracts the integer minor-unit count from a `%Money{}` (or `nil`) —
  the ADR-036 §4.5 consumer-sweep helper kernel/UI code uses to keep downstream
  integer-cents math (`mrr_delta_cents`, `dollars/1` formatters, …) unchanged while
  reading the new Money-typed source columns.
  """

  use Ash.Type.NewType, subtype_of: AshMoney.Types.Money

  @doc "Self-classification for `Samen.Pii.Classification`: money is non-PII (ADR-036 D1)."
  def samen_pii_class, do: :non_pii

  @doc """
  The integer minor-unit (cents) count for a `%Money{}` value, or `0` for `nil`.

  Rounds half-up to the currency's exponent-2 minor unit (matching the prior
  `_cents :integer` convention this type replaces). Used by kernel/UI consumers
  that keep integer-cents math downstream of a Money-typed read (ADR-036 §4.5).

      iex> Samen.Type.Money.cents(Money.new(:USD, "12.34"))
      1234

      iex> Samen.Type.Money.cents(nil)
      0
  """
  @spec cents(Money.t() | nil) :: integer()
  def cents(nil), do: 0

  def cents(%Money{amount: amount}) do
    amount
    |> Decimal.mult(100)
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  @doc """
  The inverse of `cents/1`: builds a `%Money{}` from an integer minor-unit count
  and a currency. Thin delegate to `Money.from_integer/2` — seeds / test-support
  writers that previously wrote `value_cents:`/`unit_amount_cents:` + `currency:`
  pairs (ADR-036 §4.5(5)) construct the replacement Money value with this.

      iex> Samen.Type.Money.from_cents(1234, :USD)
      Money.new(:USD, "12.34")
  """
  @spec from_cents(integer(), atom() | String.t()) :: Money.t()
  def from_cents(cents, currency \\ :USD) when is_integer(cents) do
    Money.from_integer(cents, currency)
  end
end
