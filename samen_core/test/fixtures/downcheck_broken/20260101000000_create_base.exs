defmodule Samen.DownCheckBroken.CreateBase do
  # Bootstrap for the broken down-check fixture.
  use Ecto.Migration

  def up do
    create table(:dcb_widget, primary_key: false) do
      add(:dcb_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:dcb_name, :text, null: false)
    end
  end

  def down do
    drop(table(:dcb_widget))
  end
end
