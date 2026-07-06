defmodule Demo.Repo.Migrations.ExpandAddContactTier do
  @moduledoc """
  T2.4 EXPAND phase demo: additively add a nullable `cnt_tier` operational column to
  `cnt_contact`, and record the bake-window meta row so the paired CONTRACT migration
  can gate on it.

  ## Why this is a valid expand

    * `add_nullable_column/3` emits `ALTER TABLE ... ADD COLUMN cnt_tier TEXT` — a
      nullable, defaulted, backward-compatible add. The old binary keeps running
      against the new schema (doc §runs 2), so rollback-by-redeploy stays safe.
    * `expand_setup(change_key: ...)` sets the DDL timeout posture (lock 5s /
      statement 15s) AND writes the `samen_migration_meta` bake-clock row.
    * A `change/0` so the reversible executes flip on `down` — the expand is
      reversible (down/0 CI check exercises it).

  `cnt_tier` is an operational shadow column (not an Ash attribute, like `cnt_notes`),
  so it is added to the `catalog_parity_allow_list` in config rather than catalogued.
  A real product would instead add an Ash attribute + `catalog_sync(only: [:tier])`.
  """
  use Samen.Migration, phase: :expand

  @change_key "demo_contact_tier"

  def change do
    expand_setup(change_key: @change_key)
    add_nullable_column(:cnt_contact, :cnt_tier, :text, default: "standard")
  end
end
