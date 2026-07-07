defmodule Driftwood.Repo.Migrations.DrillExpandSettlementNote do
  @moduledoc """
  T5.5 PITR game-day EXPAND phase (the reversible, additive migration whose tested
  `down/0` is exercised in recovery ARM (i)).

  Additively adds a nullable operational column `stl_settlement_note` to
  `stl_settlement`, and records the bake-window meta row so a paired CONTRACT could
  gate on it. This is a valid expand:

    * `add_nullable_column/3` emits `ALTER TABLE ... ADD COLUMN stl_settlement_note
      TEXT` — a nullable, defaulted, backward-compatible add. The old binary keeps
      running against the new schema (doc §runs 2), so rollback-by-redeploy is safe.
    * `expand_setup(change_key: ...)` sets the DDL timeout posture AND writes the
      `samen_migration_meta` bake-clock row.
    * A `change/0` so `down` cleanly reverses the expand — this is the load-bearing
      `down/0` recovery ARM (i) drives.

  This migration lives in `priv/drills/expand_migrations/` (NOT the CI migration
  path), so the normal Driftwood schema/CI is untouched; the game-day orchestrator
  applies it against the throwaway drill DB only.
  """
  use Samen.Migration, phase: :expand

  @change_key "drill_settlement_note"

  def change do
    expand_setup(change_key: @change_key)
    add_nullable_column(:stl_settlement, :stl_settlement_note, :text, default: "")
  end
end
