defmodule Driftwood.Repo.Migrations.SupportTicketChatDedupeIdx do
  @moduledoc """
  T60 — the framework chat offline-escalation dedupe backstop, adopted by driftwood
  (freight vertical) exactly like every other Support-Ticket host. A partial-unique
  index on `(fsk_org_id, fsk_external_id) WHERE fsk_external_id IS NOT NULL` makes a
  CONCURRENT double-escalation of the same chat structurally impossible (one ticket per
  chat); it mirrors the framework operator-mount template so a NON-demo adopter inherits
  the same guarantee. PARTIAL so normal tickets (external_id NULL) are unconstrained.

  Index NAME matches the Support Ticket blueprint's `unique_index_names`
  (`fsk_ticket_chat_dedupe_idx`) so AshPostgres maps a violation to a clean `{:error, _}`.
  """
  use Ecto.Migration

  def up do
    create(
      unique_index(:fsk_ticket, [:fsk_org_id, :fsk_external_id],
        where: "fsk_external_id IS NOT NULL",
        name: "fsk_ticket_chat_dedupe_idx"
      )
    )
  end

  def down do
    drop(index(:fsk_ticket, [:fsk_org_id, :fsk_external_id], name: "fsk_ticket_chat_dedupe_idx"))
  end
end
