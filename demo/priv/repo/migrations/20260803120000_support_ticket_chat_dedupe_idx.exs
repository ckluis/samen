defmodule Demo.Repo.Migrations.SupportTicketChatDedupeIdx do
  @moduledoc """
  T60 — the atomic dedupe backstop for chat offline-escalation.

  A partial-unique index on `(stk_org_id, stk_external_id) WHERE stk_external_id IS NOT
  NULL` makes a CONCURRENT double-escalation of the same chat structurally impossible:
  the escalated ticket is born carrying `external_id = "chat:<thread_ref>"`, so two
  racing escalations of the same chat collide here — exactly one insert wins and the
  loser gets a clean unique-violation (mapped by the Ticket blueprint's
  `unique_index_names` to an Ash `{:error, _}`, never a fabricated success), which the
  capability turns into `:already_escalated`.

  PARTIAL by design: normal inbound/support tickets carry `stk_external_id = NULL` and
  are UNCONSTRAINED — no regression to the T59 inbound flow (and helpdesk-integration
  external ids that happen to repeat NULL are fine; only non-NULL ids are deduped).

  The index NAME (`stk_ticket_chat_dedupe_idx`) MUST match the blueprint's
  `unique_index_names` entry so AshPostgres maps the constraint error cleanly.
  """
  use Ecto.Migration

  def up do
    create(
      unique_index(:stk_ticket, [:stk_org_id, :stk_external_id],
        where: "stk_external_id IS NOT NULL",
        name: "stk_ticket_chat_dedupe_idx"
      )
    )
  end

  def down do
    drop(index(:stk_ticket, [:stk_org_id, :stk_external_id], name: "stk_ticket_chat_dedupe_idx"))
  end
end
