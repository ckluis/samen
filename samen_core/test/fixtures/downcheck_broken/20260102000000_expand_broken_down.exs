defmodule Samen.DownCheckBroken.ExpandBrokenDown do
  # A DELIBERATELY BROKEN expand migration: it declares itself :expand but its `up/0`
  # runs a raw one-way `execute/1` and it ships NO `down/0`. Ecto cannot reverse it,
  # so `Ecto.Migrator.run(:down, ...)` raises Ecto.MigrationError. This is the
  # red-path fixture: the down/0 CI check MUST flag this expand as broken.
  use Samen.Migration, phase: :expand

  def up do
    expand_setup()
    execute("ALTER TABLE dcb_widget ADD COLUMN dcb_color TEXT")
  end

  # No down/0, and up/0 uses an irreversible execute/1 → not reversible.
end
