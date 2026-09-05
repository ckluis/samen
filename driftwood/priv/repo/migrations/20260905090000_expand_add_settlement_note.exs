defmodule Driftwood.Repo.Migrations.ExpandAddSettlementNote do
  @moduledoc """
  UXD-04: EXPAND phase — additively add a nullable operational column
  `stl_settlement_note` to `stl_settlement`, and record the bake-window meta row
  so a paired CONTRACT migration could gate on it.

  This lands the SAME column addition already engineered and reviewed as
  `priv/drills/expand_migrations/20260707210000_drill_expand_settlement_note.exs`
  (T5.5 PITR game-day EXPAND phase), but here it runs against the REAL CI
  migration path (`priv/repo/migrations/`) rather than only the throwaway
  game-day drill DB. Landing it here is what makes `mix samen.verify.migrations`
  — and therefore `driftwood/ci.sh` step 7/20 — actually exercise a `down/0` for
  Driftwood: at HEAD this repo carried zero `:expand`-tagged migrations in its
  real migration path (`samen-oss-burndown/_orch/verify/T12-verdict.json`), so
  the down/0 CI check ran over an empty set and could not have caught a broken
  down.

  ## Why this is a valid expand

    * `add_nullable_column/3` emits `ALTER TABLE ... ADD COLUMN stl_settlement_note
      TEXT` — a nullable, defaulted, backward-compatible add. The old binary keeps
      running against the new schema, so rollback-by-redeploy stays safe.
    * `expand_setup(change_key: ...)` sets the DDL timeout posture AND writes the
      `samen_migration_meta` bake-clock row.
    * A `change/0` so the reversible executes flip on `down` — the expand is
      reversible (the down/0 CI check exercises it).

  `stl_settlement_note` is an operational shadow column (not an Ash attribute),
  so it is added to `:driftwood, :catalog_parity_allow_list` in config rather
  than catalogued — the same pattern demo already uses for `cnt_tier`
  (`demo/priv/repo/migrations/20260705120000_expand_add_contact_tier.exs`).
  """
  use Samen.Migration, phase: :expand

  @change_key "driftwood_settlement_note"

  def change do
    expand_setup(change_key: @change_key)
    add_nullable_column(:stl_settlement, :stl_settlement_note, :text, default: "")
  end
end
