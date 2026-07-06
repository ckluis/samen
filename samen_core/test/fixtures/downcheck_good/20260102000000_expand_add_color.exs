defmodule Samen.DownCheckGood.ExpandAddColor do
  # A well-formed EXPAND migration: additive nullable column via the helper, which
  # emits a reversible ALTER TABLE ADD COLUMN / DROP COLUMN pair. DownCheck must be
  # able to step this down and back up cleanly.
  use Samen.Migration, phase: :expand

  # change/0 so the reversible executes (expand_setup timeouts + ADD/DROP COLUMN)
  # flip automatically on down — that is what makes the expand reversible.
  def change do
    expand_setup()
    add_nullable_column(:dcg_widget, :dcg_color, :text)
  end
end
