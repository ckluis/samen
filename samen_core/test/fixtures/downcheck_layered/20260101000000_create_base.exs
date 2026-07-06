defmodule Samen.DownCheckLayered.CreateBase do
  # Bootstrap for the LAYERED down-check regression fixture. Not phase-tagged, so
  # DownCheck skips it — but it migrates up so the expand has a table to touch.
  use Ecto.Migration

  def up do
    create table(:dcl_widget, primary_key: false) do
      add(:dcl_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:dcl_name, :text, null: false)
    end
  end

  def down do
    drop(table(:dcl_widget))
  end
end
