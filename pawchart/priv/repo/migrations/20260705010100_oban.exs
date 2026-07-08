defmodule PawChart.Repo.Migrations.AddOban do
  @moduledoc "Installs Oban versioned tables (same-tx reveal-grant auto-revoke)."
  use Ecto.Migration

  def up, do: Oban.Migrations.up()
  def down, do: Oban.Migrations.down()
end
