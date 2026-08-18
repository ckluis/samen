defmodule Driftwood.Repo.Migrations.H1MoneyMigration do
  @moduledoc """
  ADR-036 H1/D7 — the pre-1.0 **destructive single data-copy migration** replacing
  the paired `_cents :integer` + `currency :string` convention on CRM Opportunity
  (`fop_opportunity`) and BOTH Billing Price mounts — the tenant mount
  (`fbr_price`, `Driftwood.Billing.Price`) and the operator mount (`dpr_price`,
  `Driftwood.Operator.Price`) — with ONE `money_with_currency` composite column
  each. Old columns dropped in the SAME migration — no deprecation window (M6;
  ADR-037 §5.2). Requires `20260721020000_install_ash_money_extension` (the
  `money_with_currency` type) to have run first.

  See `Demo.Repo.Migrations.H1MoneyMigration` for the full per-column sequence
  rationale (§4.3) — identical shape, three tables here (one Opportunity, two
  Price mounts) instead of demo's two.

  Contract-phase: never itself the target of the expand `down/0` round-trip
  check, but ships a REAL, working `down/0` below — see
  `Demo.Repo.Migrations.H1MoneyMigration`'s moduledoc for why (`DownCheck` rolls
  the whole stack down through every migration above an `:expand` under test,
  including this one).
  """
  use Samen.Migration, phase: :contract

  def up do
    # ---- CRM Opportunity (fop_opportunity): fop_value_cents/fop_currency → fop_value ----
    alter table(:fop_opportunity) do
      add(:fop_value, :money_with_currency)
    end

    execute(
      "UPDATE fop_opportunity SET fop_value = ROW(fop_currency, fop_value_cents::numeric / 100)::money_with_currency"
    )

    alter table(:fop_opportunity) do
      remove(:fop_value_cents)
      remove(:fop_currency)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'fop_opportunity' AND fld_column_name IN ('fop_value_cents', 'fop_currency')")
    catalog_sync([Driftwood.Crm.Opportunity], only: [:value])

    # ---- Billing Price, TENANT mount (fbr_price): fbr_unit_amount_cents/fbr_currency → fbr_unit_amount ----
    alter table(:fbr_price) do
      add(:fbr_unit_amount, :money_with_currency)
    end

    execute(
      "UPDATE fbr_price SET fbr_unit_amount = ROW(fbr_currency, fbr_unit_amount_cents::numeric / 100)::money_with_currency"
    )

    alter table(:fbr_price) do
      remove(:fbr_unit_amount_cents)
      remove(:fbr_currency)
    end

    execute("ALTER TABLE fbr_price ALTER COLUMN fbr_unit_amount SET NOT NULL")

    execute("DELETE FROM fld_field WHERE fld_table_name = 'fbr_price' AND fld_column_name IN ('fbr_unit_amount_cents', 'fbr_currency')")
    catalog_sync([Driftwood.Billing.Price], only: [:unit_amount])

    # ---- Billing Price, OPERATOR mount (dpr_price): dpr_unit_amount_cents/dpr_currency → dpr_unit_amount ----
    alter table(:dpr_price) do
      add(:dpr_unit_amount, :money_with_currency)
    end

    execute(
      "UPDATE dpr_price SET dpr_unit_amount = ROW(dpr_currency, dpr_unit_amount_cents::numeric / 100)::money_with_currency"
    )

    alter table(:dpr_price) do
      remove(:dpr_unit_amount_cents)
      remove(:dpr_currency)
    end

    execute("ALTER TABLE dpr_price ALTER COLUMN dpr_unit_amount SET NOT NULL")

    execute("DELETE FROM fld_field WHERE fld_table_name = 'dpr_price' AND fld_column_name IN ('dpr_unit_amount_cents', 'dpr_currency')")
    catalog_sync([Driftwood.Operator.Price], only: [:unit_amount])
  end

  def down do
    # ---- Billing Price, OPERATOR mount (dpr_price): dpr_unit_amount → dpr_unit_amount_cents/dpr_currency ----
    alter table(:dpr_price) do
      add(:dpr_unit_amount_cents, :integer)
      add(:dpr_currency, :text, default: "USD")
    end

    execute(
      "UPDATE dpr_price SET dpr_unit_amount_cents = round((dpr_unit_amount).amount * 100)::int, dpr_currency = (dpr_unit_amount).currency_code"
    )

    execute("ALTER TABLE dpr_price ALTER COLUMN dpr_unit_amount_cents SET NOT NULL")
    execute("ALTER TABLE dpr_price ALTER COLUMN dpr_currency SET NOT NULL")

    alter table(:dpr_price) do
      remove(:dpr_unit_amount)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'dpr_price' AND fld_column_name = 'dpr_unit_amount'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('dpr_price', 'dpr_unit_amount_cents', 'unit_amount_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('dpr_price', 'dpr_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    # ---- Billing Price, TENANT mount (fbr_price): fbr_unit_amount → fbr_unit_amount_cents/fbr_currency ----
    alter table(:fbr_price) do
      add(:fbr_unit_amount_cents, :integer)
      add(:fbr_currency, :text, default: "USD")
    end

    execute(
      "UPDATE fbr_price SET fbr_unit_amount_cents = round((fbr_unit_amount).amount * 100)::int, fbr_currency = (fbr_unit_amount).currency_code"
    )

    execute("ALTER TABLE fbr_price ALTER COLUMN fbr_unit_amount_cents SET NOT NULL")
    execute("ALTER TABLE fbr_price ALTER COLUMN fbr_currency SET NOT NULL")

    alter table(:fbr_price) do
      remove(:fbr_unit_amount)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'fbr_price' AND fld_column_name = 'fbr_unit_amount'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('fbr_price', 'fbr_unit_amount_cents', 'unit_amount_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('fbr_price', 'fbr_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    # ---- CRM Opportunity (fop_opportunity): fop_value → fop_value_cents/fop_currency ----
    alter table(:fop_opportunity) do
      add(:fop_value_cents, :integer, default: 0)
      add(:fop_currency, :text, default: "USD")
    end

    execute(
      "UPDATE fop_opportunity SET fop_value_cents = round((fop_value).amount * 100)::int, fop_currency = (fop_value).currency_code"
    )

    alter table(:fop_opportunity) do
      remove(:fop_value)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'fop_opportunity' AND fld_column_name = 'fop_value'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('fop_opportunity', 'fop_value_cents', 'value_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('fop_opportunity', 'fop_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )
  end
end
