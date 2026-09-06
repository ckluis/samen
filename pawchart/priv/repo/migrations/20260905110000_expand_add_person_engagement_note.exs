defmodule PawChart.Repo.Migrations.ExpandAddPersonEngagementNote do
  @moduledoc """
  UXD-04 follow-up (W5): EXPAND phase — additively add a nullable operational column
  `vcb_engagement_note` to `vcb_person`, and record the bake-window meta row so a
  paired CONTRACT migration could gate on it.

  At HEAD this repo (like `samen_web`) carried zero `:expand`-tagged migrations in its
  real migration path (`priv/repo/migrations/`), so `mix samen.verify.migrations` ran
  its `down/0` check over an empty set here and could not have caught a broken down.
  This mirrors the recipe already landed for `driftwood`
  (`driftwood/priv/repo/migrations/20260905090000_expand_add_settlement_note.exs`) and
  `demo` (`demo/priv/repo/migrations/20260705120000_expand_add_contact_tier.exs`).

  ## Why this is a valid expand

    * `add_nullable_column/3` emits `ALTER TABLE ... ADD COLUMN vcb_engagement_note
      TEXT` — a nullable, defaulted, backward-compatible add. The old binary keeps
      running against the new schema, so rollback-by-redeploy stays safe.
    * `expand_setup(change_key: ...)` sets the DDL timeout posture AND writes the
      `samen_migration_meta` bake-clock row.
    * A `change/0` so the reversible executes flip on `down` — the expand is
      reversible (the down/0 CI check exercises it).

  `vcb_engagement_note` is an operational shadow column (not an Ash attribute), so it
  is added to `:pawchart, :catalog_parity_allow_list` in config rather than
  catalogued — the same pattern `driftwood`/`demo` already use.

  `pawchart`'s `priv/repo/migrations` has no `priv/drills/` directory (checked before
  this file was written; see W5's `work/collision-check.log`), so there is no drill/
  real-path collision class to worry about here.
  """
  use Samen.Migration, phase: :expand

  @change_key "pawchart_person_engagement_note"

  def change do
    expand_setup(change_key: @change_key)
    add_nullable_column(:vcb_person, :vcb_engagement_note, :text, default: "")
  end
end
