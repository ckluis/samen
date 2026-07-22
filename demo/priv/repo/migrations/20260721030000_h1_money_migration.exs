defmodule Demo.Repo.Migrations.H1MoneyMigration do
  @moduledoc """
  ADR-036 H1/D7 — the pre-1.0 **destructive single data-copy migration** replacing
  the paired `_cents :integer` + `currency :string` convention on CRM Opportunity
  (`opp_opportunity`) and Billing Price (`bpr_price`) with ONE
  `money_with_currency` composite column each (`opp_value`, `bpr_unit_amount`).
  Old columns dropped in the SAME migration — no deprecation window (M6; ADR-037
  §5.2). Requires `20260721020000_install_ash_money_extension` (the
  `money_with_currency` type) to have run first.

  Per-resource, per-column sequence (§4.3):

    1. ALTER TABLE ADD COLUMN <new> money_with_currency
    2. UPDATE ... SET <new> = ROW(<currency>, <cents>::numeric / 100)::money_with_currency
       — a lossless bijection over the existing integer-cents data.
    3. ALTER TABLE DROP COLUMN <cents>, DROP COLUMN <currency> — same migration.
    4. Catalog reconciliation: the dropped columns' `fld_field` rows are removed,
       the new composite column's `fld_field` row is added (`catalog_sync/2`,
       `only:` scoped) — keeps `catalog_parity` clean (name-only parity; the
       composite type is invisible to that verifier).

  Contract-phase: this migration is never ITSELF the target of the expand
  `down/0` round-trip check (`samen.verify.migrations` only exercises
  `:expand`-tagged migrations by name — §4.3, "PITR-covered ... not
  `down/0`-down-tested"). It still SHIP a real, working `down/0` below —
  `Samen.Migration.DownCheck` rolls the WHOLE stack down to just before each
  older `:expand` migration under test (`Ecto.Migrator.run(:down, to: ...)`),
  which runs the `down/0` of every migration applied above it, including this
  one. A raising/absent `down/0` here would break every earlier expand's
  round-trip test, not just this migration's own (non-tested) reversal. The
  down/0 below is the documented reversal recipe, made real: re-add the pair,
  backfill from the composite (a lossless bijection over the existing
  integer-cents data, since the forward transform is exact), drop the
  composite, restore the catalog rows.
  """
  use Samen.Migration, phase: :contract

  def up do
    # ---- CRM Opportunity (opp_opportunity): opp_value_cents/opp_currency → opp_value ----
    alter table(:opp_opportunity) do
      add(:opp_value, :money_with_currency)
    end

    execute(
      "UPDATE opp_opportunity SET opp_value = ROW(opp_currency, opp_value_cents::numeric / 100)::money_with_currency"
    )

    alter table(:opp_opportunity) do
      remove(:opp_value_cents)
      remove(:opp_currency)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'opp_opportunity' AND fld_column_name IN ('opp_value_cents', 'opp_currency')")
    catalog_sync([Demo.CrmScope.Opportunity], only: [:value])

    # ---- Billing Price (bpr_price): bpr_unit_amount_cents/bpr_currency → bpr_unit_amount ----
    alter table(:bpr_price) do
      add(:bpr_unit_amount, :money_with_currency)
    end

    execute(
      "UPDATE bpr_price SET bpr_unit_amount = ROW(bpr_currency, bpr_unit_amount_cents::numeric / 100)::money_with_currency"
    )

    alter table(:bpr_price) do
      remove(:bpr_unit_amount_cents)
      remove(:bpr_currency)
    end

    # bpr_unit_amount_cents was NOT NULL — every existing row was just backfilled
    # above, so the composite replacement can carry the same guarantee forward.
    execute("ALTER TABLE bpr_price ALTER COLUMN bpr_unit_amount SET NOT NULL")

    execute("DELETE FROM fld_field WHERE fld_table_name = 'bpr_price' AND fld_column_name IN ('bpr_unit_amount_cents', 'bpr_currency')")
    catalog_sync([Demo.BillingScope.Price], only: [:unit_amount])
  end

  def down do
    # ---- Billing Price (bpr_price): bpr_unit_amount → bpr_unit_amount_cents/bpr_currency ----
    alter table(:bpr_price) do
      add(:bpr_unit_amount_cents, :integer)
      add(:bpr_currency, :text, default: "USD")
    end

    execute(
      "UPDATE bpr_price SET bpr_unit_amount_cents = round((bpr_unit_amount).amount * 100)::int, bpr_currency = (bpr_unit_amount).currency_code"
    )

    execute("ALTER TABLE bpr_price ALTER COLUMN bpr_unit_amount_cents SET NOT NULL")
    execute("ALTER TABLE bpr_price ALTER COLUMN bpr_currency SET NOT NULL")

    alter table(:bpr_price) do
      remove(:bpr_unit_amount)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'bpr_price' AND fld_column_name = 'bpr_unit_amount'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('bpr_price', 'bpr_unit_amount_cents', 'unit_amount_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('bpr_price', 'bpr_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    # ---- CRM Opportunity (opp_opportunity): opp_value → opp_value_cents/opp_currency ----
    alter table(:opp_opportunity) do
      add(:opp_value_cents, :integer, default: 0)
      add(:opp_currency, :text, default: "USD")
    end

    execute(
      "UPDATE opp_opportunity SET opp_value_cents = round((opp_value).amount * 100)::int, opp_currency = (opp_value).currency_code"
    )

    alter table(:opp_opportunity) do
      remove(:opp_value)
    end

    execute("DELETE FROM fld_field WHERE fld_table_name = 'opp_opportunity' AND fld_column_name = 'opp_value'")

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('opp_opportunity', 'opp_value_cents', 'value_cents', 'Integer') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )

    execute(
      "INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type) VALUES " <>
        "('opp_opportunity', 'opp_currency', 'currency', 'String') ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING"
    )
  end
end
