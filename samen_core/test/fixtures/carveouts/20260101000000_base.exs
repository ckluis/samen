defmodule Samen.Carveouts.Base do
  use Ecto.Migration

  def up do
    create table(:cov_widget, primary_key: false) do
      add(:cov_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      add(:cov_name, :text, null: false)
      add(:cov_backfilled, :text)
    end

    # Seed rows so the chunked backfill has work to do.
    for i <- 1..25 do
      execute("INSERT INTO cov_widget (cov_name) VALUES ('w#{i}')")
    end
  end

  def down do
    drop(table(:cov_widget))
  end
end
