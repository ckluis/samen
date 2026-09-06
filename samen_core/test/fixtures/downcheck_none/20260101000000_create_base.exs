defmodule Samen.DownCheckNone.CreateBase do
  # Fixture for the `--min-expand` floor check: a migrations directory with a plain
  # (un-phased) migration and ZERO `phase: :expand` migrations. Used to prove the
  # opt-in property — no floor declared, count 0, still GREEN — and the floor's own
  # RED path when a floor IS declared against this same zero-expand directory.
  use Ecto.Migration

  def up do
    create table(:dcn_widget, primary_key: false) do
      add(:dcn_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:dcn_name, :text, null: false)
    end
  end

  def down do
    drop(table(:dcn_widget))
  end
end
