defmodule PawChart.Repo.Migrations.H1MoneyMigration do
  @moduledoc """
  ADR-036 H1/D7 — the pre-1.0 **destructive single data-copy migration** replacing
  the paired `_cents :integer` + `currency :string` convention on CRM Opportunity
  (`vcd_opportunity`) and Billing Price (`ppc_price`) with ONE
  `money_with_currency` composite column each (`vcd_value`, `ppc_unit_amount`).
  Old columns dropped in the SAME migration — no deprecation window (M6; ADR-037
  §5.2). Requires `20260721020000_install_ash_money_extension` (the
  `money_with_currency` type) to have run first.

  See `Demo.Repo.Migrations.H1MoneyMigration` for the full per-column sequence
  rationale (§4.3) — identical shape.

  Contract-phase: never itself the target of the expand `down/0` round-trip
  check, but ships a REAL, working `down/0` below — see
  `Demo.Repo.Migrations.H1MoneyMigration`'s moduledoc for why (`DownCheck` rolls
  the whole stack down through every migration above an `:expand` under test,
  including this one).
  """
  use Samen.Migration, phase: :contract

  def up do
    # ---- CRM Opportunity (vcd_opportunity): vcd_value_cents/vcd_currency → vcd_value ----
    alter table(:vcd_opportunity) do
      add(:vcd_value, :money_with_currency)
    end

    execute(
      "UPDATE vcd_opportunity SET vcd_value = ROW(vcd_currency, vcd_value_cents::numeric / 100)::money_with_currency"
    )

    alter table(:vcd_opportunity) do
      remove(:vcd_value_cents)
      remove(:vcd_currency)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'vcd_opportunity' AND fld_column_name IN ('vcd_value_cents', 'vcd_currency')")
    catalog_sync([PawChart.Crm.Opportunity], only: [:value])

    # ---- Billing Price (ppc_price): ppc_unit_amount_cents/ppc_currency → ppc_unit_amount ----
    alter table(:ppc_price) do
      add(:ppc_unit_amount, :money_with_currency)
    end

    execute(
      "UPDATE ppc_price SET ppc_unit_amount = ROW(ppc_currency, ppc_unit_amount_cents::numeric / 100)::money_with_currency"
    )

    alter table(:ppc_price) do
      remove(:ppc_unit_amount_cents)
      remove(:ppc_currency)
    end

    execute("ALTER TABLE ppc_price ALTER COLUMN ppc_unit_amount SET NOT NULL")

    execute("DELETE FROM fld_field WHERE fld_table_name = 'ppc_price' AND fld_column_name IN ('ppc_unit_amount_cents', 'ppc_currency')")
    catalog_sync([PawChart.Billing.Price], only: [:unit_amount])
  end

  def down do
    # ---- Billing Price (ppc_price): ppc_unit_amount → ppc_unit_amount_cents/ppc_currency ----
    alter table(:ppc_price) do
      add(:ppc_unit_amount_cents, :integer)
      add(:ppc_currency, :text, default: "USD")
    end

    execute(
      "UPDATE ppc_price SET ppc_unit_amount_cents = round((ppc_unit_amount).amount * 100)::int, ppc_currency = (ppc_unit_amount).currency_code"
    )

    execute("ALTER TABLE ppc_price ALTER COLUMN ppc_unit_amount_cents SET NOT NULL")
    execute("ALTER TABLE ppc_price ALTER COLUMN ppc_currency SET NOT NULL")

    alter table(:ppc_price) do
      remove(:ppc_unit_amount)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'ppc_price' AND fld_column_name = 'ppc_unit_amount'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('ppc_price', 'ppc_unit_amount_cents', 'unit_amount_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('ppc_price', 'ppc_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    # ---- CRM Opportunity (vcd_opportunity): vcd_value → vcd_value_cents/vcd_currency ----
    alter table(:vcd_opportunity) do
      add(:vcd_value_cents, :integer, default: 0)
      add(:vcd_currency, :text, default: "USD")
    end

    execute(
      "UPDATE vcd_opportunity SET vcd_value_cents = round((vcd_value).amount * 100)::int, vcd_currency = (vcd_value).currency_code"
    )

    alter table(:vcd_opportunity) do
      remove(:vcd_value)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'vcd_opportunity' AND fld_column_name = 'vcd_value'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('vcd_opportunity', 'vcd_value_cents', 'value_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('vcd_opportunity', 'vcd_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )
  end
end
