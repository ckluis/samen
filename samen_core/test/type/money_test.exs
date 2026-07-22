defmodule Samen.Type.MoneyTest do
  @moduledoc """
  H1 — `Samen.Type.Money` (ADR-036 D1, T12 done-criterion 1): the thin samen-owned
  wrapper over `AshMoney.Types.Money` (ADR-037 §5.2 ADOPT).

  Two halves:

    * A pure `Ash.Type` unit suite (`describe "Ash.Type contract"`) — cast/dump/
      equality/currency-mismatch rejection + the `cents/1` arithmetic helper,
      mirroring the style of `Samen.TypeCompositeTest` (FullName/Emails/Phones).
    * A PII-posture suite (`describe "PII posture (ADR-036 D1 / ADR-034 gate)"`)
      proving the type self-classifies `:non_pii` and that classification is
      backed by the foundry-SHIPPED `TypeClearance` entry (no host config
      required) — the ADR-034 fail-closed gate `Samen.PiiTypeClearanceTest` proves
      generically, proven here for this concrete type (INV-1).
    * A real-Postgres round-trip suite (`describe "Postgres composite round-trip"`)
      proving the `money_with_currency` storage shape actually persists/reads back
      through `SamenCore.TestRepo`, and that the H1 §4.3 backfill SQL formula
      (`ROW(currency, cents::numeric / 100)::money_with_currency`) is a lossless,
      value-exact bijection over representative integer-cents data — the
      "migration test" done-criterion 2 asks for, proven against the exact SQL the
      per-host data-copy migrations execute.
  """

  use ExUnit.Case, async: false

  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    :ok
  end

  # ==========================================================================
  # Ash.Type contract — cast / dump / equality / currency-mismatch rejection
  # ==========================================================================

  describe "Ash.Type contract" do
    test "storage_type is the money_with_currency composite" do
      assert Ash.Type.storage_type(Samen.Type.Money, []) == :money_with_currency
    end

    test "cast_input accepts a %Money{} struct, a {currency, amount} tuple, and a map" do
      want = Money.new!(:USD, "12.34")

      assert {:ok, got} = Ash.Type.cast_input(Samen.Type.Money, want)
      assert Money.equal?(got, want)

      assert {:ok, got} = Ash.Type.cast_input(Samen.Type.Money, {:USD, "12.34"})
      assert Money.equal?(got, want)

      assert {:ok, got} =
               Ash.Type.cast_input(Samen.Type.Money, %{"amount" => "12.34", "currency" => "USD"})

      assert Money.equal?(got, want)
    end

    test "cast_input(nil) is nil; garbage is rejected" do
      assert Ash.Type.cast_input(Samen.Type.Money, nil) == {:ok, nil}
      assert match?({:error, _}, Ash.Type.cast_input(Samen.Type.Money, "not money"))

      assert match?(
               {:error, _},
               Ash.Type.cast_input(Samen.Type.Money, %{"amount" => "not a number", "currency" => "USD"})
             )
    end

    test "dump_to_native → cast_stored round-trips the composite value" do
      value = Money.new!(:EUR, "1234.56")

      assert {:ok, dumped} = Ash.Type.dump_to_native(Samen.Type.Money, value)
      assert {:ok, reloaded} = Ash.Type.cast_stored(Samen.Type.Money, dumped)
      assert Money.equal?(reloaded, value)
    end

    test "dump_to_native(nil) is nil" do
      assert Ash.Type.dump_to_native(Samen.Type.Money, nil) == {:ok, nil}
    end

    test "equal?/2 compares amount+currency; different currencies never equal" do
      a = Money.new!(:USD, "10.00")
      b = Money.new!(:USD, "10.00")
      c = Money.new!(:USD, "10.01")
      d = Money.new!(:EUR, "10.00")

      assert Ash.Type.equal?(Samen.Type.Money, a, b)
      refute Ash.Type.equal?(Samen.Type.Money, a, c)
      refute Ash.Type.equal?(Samen.Type.Money, a, d)
    end

    test "currency mismatch is REJECTED by arithmetic, never silently coerced" do
      usd = Money.new!(:USD, "100.00")
      eur = Money.new!(:EUR, "50.00")

      assert {:error, {ArgumentError, msg}} = Money.add(usd, eur)
      assert msg =~ "different currencies"

      assert_raise ArgumentError, ~r/different currencies/, fn ->
        Money.add!(usd, eur)
      end
    end

    test "arithmetic helpers: same-currency add/sub work; cents/1 extracts minor units" do
      a = Money.new!(:USD, "10.00")
      b = Money.new!(:USD, "2.50")

      assert {:ok, sum} = Money.add(a, b)
      assert Money.equal?(sum, Money.new!(:USD, "12.50"))

      assert {:ok, diff} = Money.sub(a, b)
      assert Money.equal?(diff, Money.new!(:USD, "7.50"))

      assert Samen.Type.Money.cents(Money.new!(:USD, "12.34")) == 1234
      assert Samen.Type.Money.cents(Money.new!(:USD, "0.00")) == 0
      assert Samen.Type.Money.cents(Money.new!(:USD, "5")) == 500
      assert Samen.Type.Money.cents(nil) == 0
    end
  end

  # ==========================================================================
  # PII posture (ADR-036 D1 / ADR-034 gate; INV-1 done-criterion 3)
  # ==========================================================================

  describe "PII posture (ADR-036 D1 / ADR-034 gate)" do
    test "self-classifies :non_pii" do
      assert Samen.Type.Money.samen_pii_class() == :non_pii
    end

    test "GREEN: classifies :non_pii on a FRESH host with NO configured clearances — " <>
           "the ADR-036 clearance is foundry-SHIPPED, not host-config-dependent" do
      prior = Application.get_env(:samen_core, :non_pii_type_clearances)
      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:samen_core, :non_pii_type_clearances)
          _ -> Application.put_env(:samen_core, :non_pii_type_clearances, prior)
        end
      end)

      # Simulate a host that ships NO type clearances of its own.
      Application.put_env(:samen_core, :non_pii_type_clearances, [])

      assert TypeClearance.cleared?(Samen.Type.Money)
      assert Classification.classify(Samen.Type.Money) == :non_pii
      assert Classification.classified?(Samen.Type.Money)
    end

    test "the shipped clearance is genuinely two-distinct-party (not self-reviewed)" do
      shipped = Enum.find(TypeClearance.clearances(), &(&1.type == Samen.Type.Money))

      refute is_nil(shipped)
      assert shipped.cleared_by != shipped.reviewed_by
      assert is_binary(shipped.reason) and String.trim(shipped.reason) != ""
    end
  end

  # ==========================================================================
  # Postgres composite round-trip + the H1 §4.3 backfill formula (done-criterion 2)
  # ==========================================================================

  describe "Postgres composite round-trip" do
    test "a Money value persists through a real money_with_currency column and reads back exact" do
      Ecto.Adapters.SQL.query!(TestRepo, "CREATE TEMP TABLE money_rt (v money_with_currency) ON COMMIT DROP", [])

      value = Money.new!(:GBP, "42.07")
      {:ok, {currency, amount}} = Ash.Type.dump_to_native(Samen.Type.Money, value)

      Ecto.Adapters.SQL.query!(
        TestRepo,
        "INSERT INTO money_rt (v) VALUES (ROW($1, $2)::money_with_currency)",
        [currency, amount]
      )

      %{rows: [[{loaded_currency, loaded_amount}]]} =
        Ecto.Adapters.SQL.query!(TestRepo, "SELECT v FROM money_rt", [])

      assert {:ok, reloaded} =
               Ash.Type.cast_stored(Samen.Type.Money, {loaded_currency, loaded_amount})

      assert Money.equal?(reloaded, value)
    end

    test "the H1 §4.3 backfill UPDATE is a value-exact bijection over seeded paired-column rows" do
      # Simulate the PRE-migration shape (paired _cents integer + currency string),
      # seed representative rows (a non-round-dollar amount, zero, a large amount,
      # and a single-digit-cents amount), then run the EXACT backfill SQL the
      # per-host data-copy migration executes (ADR-036 §4.3 step 3), and assert the
      # new composite column holds the value-exact conversion for every row.
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "CREATE TEMP TABLE opp_backfill_rt (id serial PRIMARY KEY, value_cents integer, currency text) ON COMMIT DROP",
        []
      )

      seeded = [
        {1234, "USD"},
        {0, "USD"},
        {250_000, "USD"},
        {5, "EUR"},
        {99_999_999, "GBP"}
      ]

      Enum.each(seeded, fn {cents, currency} ->
        Ecto.Adapters.SQL.query!(
          TestRepo,
          "INSERT INTO opp_backfill_rt (value_cents, currency) VALUES ($1, $2)",
          [cents, currency]
        )
      end)

      # §4.3 step 2: add the composite column.
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "ALTER TABLE opp_backfill_rt ADD COLUMN value money_with_currency",
        []
      )

      # §4.3 step 3: the backfill — existing integer-cents ÷ 100 → numeric amount;
      # currency string → the composite's char(3).
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "UPDATE opp_backfill_rt SET value = ROW(currency, value_cents::numeric / 100)::money_with_currency",
        []
      )

      # §4.3 step 4: drop the old pair — SAME migration, no deprecation window.
      Ecto.Adapters.SQL.query!(TestRepo, "ALTER TABLE opp_backfill_rt DROP COLUMN value_cents", [])
      Ecto.Adapters.SQL.query!(TestRepo, "ALTER TABLE opp_backfill_rt DROP COLUMN currency", [])

      %{rows: rows} =
        Ecto.Adapters.SQL.query!(TestRepo, "SELECT id, value FROM opp_backfill_rt ORDER BY id", [])

      results =
        Enum.map(rows, fn [id, {currency, amount}] ->
          {:ok, money} = Ash.Type.cast_stored(Samen.Type.Money, {currency, amount})
          {id, money}
        end)

      assert length(results) == length(seeded)

      Enum.zip(results, seeded)
      |> Enum.each(fn {{_id, money}, {cents, currency}} ->
        assert money.currency == String.to_existing_atom(currency)
        assert Samen.Type.Money.cents(money) == cents
      end)
    end
  end
end
