defmodule Samen.DownCheckGood.CreateBase do
  # Bootstrap for the good down-check fixture: a plain base table. Not phase-tagged
  # (it is not an expand under test), so DownCheck skips it — but it must migrate up
  # so the later expand has a table to add a column to.
  use Ecto.Migration

  def up do
    create table(:dcg_widget, primary_key: false) do
      add(:dcg_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:dcg_name, :text, null: false)
    end
  end

  def down do
    drop(table(:dcg_widget))
  end
end
