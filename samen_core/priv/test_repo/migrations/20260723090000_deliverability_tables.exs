defmodule SamenCore.TestRepo.Migrations.DeliverabilityTables do
  @moduledoc "T30/C4: the `dlv_email_event` + `dlv_suppression` tables (ADR-038 §4.4)."
  use Ecto.Migration
  def up, do: Samen.Delivery.DeliverabilityMigration.up()
  def down, do: Samen.Delivery.DeliverabilityMigration.down()
end
