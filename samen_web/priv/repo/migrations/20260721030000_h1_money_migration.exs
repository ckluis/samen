defmodule Samen.WebTest.Repo.Migrations.H1MoneyMigration do
  @moduledoc """
  ADR-036 H1/D7 — the pre-1.0 **destructive single data-copy migration** replacing
  the paired `_cents :integer` + `currency :string` convention on the samen_web
  test-support CRM Opportunity (`swo_opportunity`) and BOTH Billing Price mounts
  — the tenant mount (`wbr_price`, `Samen.WebTest.Billing.Price`) and the
  operator mount (`wpr_price`, `Samen.WebTest.Operator.Price`) — with ONE
  `money_with_currency` composite column each (`swo_value`, `wbr_unit_amount`,
  `wpr_unit_amount`). Old columns dropped in the SAME migration — no
  deprecation window (M6; ADR-037 §5.2). Requires
  `20260721020000_install_ash_money_extension` (the `money_with_currency` type)
  to have run first.

  See `Demo.Repo.Migrations.H1MoneyMigration` for the full per-column sequence
  rationale (§4.3) — identical shape; this is the samen_web render-test host's
  own copy of the same CRM/Billing scope mount (ADR-009 §6).

  Contract-phase: never itself the target of the expand `down/0` round-trip
  check, but ships a REAL, working `down/0` below — see
  `Demo.Repo.Migrations.H1MoneyMigration`'s moduledoc for why (`DownCheck` rolls
  the whole stack down through every migration above an `:expand` under test,
  including this one).
  """
  use Samen.Migration, phase: :contract

  def up do
    # ---- CRM Opportunity (swo_opportunity): swo_value_cents/swo_currency → swo_value ----
    alter table(:swo_opportunity) do
      add(:swo_value, :money_with_currency)
    end

    execute(
      "UPDATE swo_opportunity SET swo_value = ROW(swo_currency, swo_value_cents::numeric / 100)::money_with_currency"
    )

    alter table(:swo_opportunity) do
      remove(:swo_value_cents)
      remove(:swo_currency)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'swo_opportunity' AND fld_column_name IN ('swo_value_cents', 'swo_currency')")
    catalog_sync([Samen.WebTest.Crm.Opportunity], only: [:value])

    # ---- Billing Price (wbr_price): wbr_unit_amount_cents/wbr_currency → wbr_unit_amount ----
    alter table(:wbr_price) do
      add(:wbr_unit_amount, :money_with_currency)
    end

    execute(
      "UPDATE wbr_price SET wbr_unit_amount = ROW(wbr_currency, wbr_unit_amount_cents::numeric / 100)::money_with_currency"
    )

    alter table(:wbr_price) do
      remove(:wbr_unit_amount_cents)
      remove(:wbr_currency)
    end

    execute("ALTER TABLE wbr_price ALTER COLUMN wbr_unit_amount SET NOT NULL")

    execute("DELETE FROM fld_field WHERE fld_table_name = 'wbr_price' AND fld_column_name IN ('wbr_unit_amount_cents', 'wbr_currency')")
    catalog_sync([Samen.WebTest.Billing.Price], only: [:unit_amount])

    # ---- Billing Price, OPERATOR mount (wpr_price): wpr_unit_amount_cents/wpr_currency → wpr_unit_amount ----
    alter table(:wpr_price) do
      add(:wpr_unit_amount, :money_with_currency)
    end

    execute(
      "UPDATE wpr_price SET wpr_unit_amount = ROW(wpr_currency, wpr_unit_amount_cents::numeric / 100)::money_with_currency"
    )

    alter table(:wpr_price) do
      remove(:wpr_unit_amount_cents)
      remove(:wpr_currency)
    end

    execute("ALTER TABLE wpr_price ALTER COLUMN wpr_unit_amount SET NOT NULL")

    execute("DELETE FROM fld_field WHERE fld_table_name = 'wpr_price' AND fld_column_name IN ('wpr_unit_amount_cents', 'wpr_currency')")
    catalog_sync([Samen.WebTest.Operator.Price], only: [:unit_amount])
  end

  def down do
    # ---- Billing Price, OPERATOR mount (wpr_price): wpr_unit_amount → wpr_unit_amount_cents/wpr_currency ----
    alter table(:wpr_price) do
      add(:wpr_unit_amount_cents, :integer)
      add(:wpr_currency, :text, default: "USD")
    end

    execute(
      "UPDATE wpr_price SET wpr_unit_amount_cents = round((wpr_unit_amount).amount * 100)::int, wpr_currency = (wpr_unit_amount).currency_code"
    )

    execute("ALTER TABLE wpr_price ALTER COLUMN wpr_unit_amount_cents SET NOT NULL")
    execute("ALTER TABLE wpr_price ALTER COLUMN wpr_currency SET NOT NULL")

    alter table(:wpr_price) do
      remove(:wpr_unit_amount)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'wpr_price' AND fld_column_name = 'wpr_unit_amount'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('wpr_price', 'wpr_unit_amount_cents', 'unit_amount_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('wpr_price', 'wpr_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    # ---- Billing Price, TENANT mount (wbr_price): wbr_unit_amount → wbr_unit_amount_cents/wbr_currency ----
    alter table(:wbr_price) do
      add(:wbr_unit_amount_cents, :integer)
      add(:wbr_currency, :text, default: "USD")
    end

    execute(
      "UPDATE wbr_price SET wbr_unit_amount_cents = round((wbr_unit_amount).amount * 100)::int, wbr_currency = (wbr_unit_amount).currency_code"
    )

    execute("ALTER TABLE wbr_price ALTER COLUMN wbr_unit_amount_cents SET NOT NULL")
    execute("ALTER TABLE wbr_price ALTER COLUMN wbr_currency SET NOT NULL")

    alter table(:wbr_price) do
      remove(:wbr_unit_amount)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'wbr_price' AND fld_column_name = 'wbr_unit_amount'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('wbr_price', 'wbr_unit_amount_cents', 'unit_amount_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('wbr_price', 'wbr_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    # ---- CRM Opportunity (swo_opportunity): swo_value → swo_value_cents/swo_currency ----
    alter table(:swo_opportunity) do
      add(:swo_value_cents, :integer, default: 0)
      add(:swo_currency, :text, default: "USD")
    end

    execute(
      "UPDATE swo_opportunity SET swo_value_cents = round((swo_value).amount * 100)::int, swo_currency = (swo_value).currency_code"
    )

    alter table(:swo_opportunity) do
      remove(:swo_value)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'swo_opportunity' AND fld_column_name = 'swo_value'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('swo_opportunity', 'swo_value_cents', 'value_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('swo_opportunity', 'swo_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )
  end
end
