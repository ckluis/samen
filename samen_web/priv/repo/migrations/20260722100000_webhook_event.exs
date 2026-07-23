defmodule Samen.WebTest.Repo.Migrations.WebhookEvent do
  @moduledoc "T19/B9: the `whk_event` webhook ingress replay-store + DLQ table (ADR-038 §5.3)."
  use Ecto.Migration
  def up, do: Samen.Webhook.EventMigration.up()
  def down, do: Samen.Webhook.EventMigration.down()
end
