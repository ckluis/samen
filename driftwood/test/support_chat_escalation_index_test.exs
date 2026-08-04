defmodule Driftwood.SupportChatEscalationIndexTest do
  @moduledoc """
  T60 framework-first / leverage-guard proof: a NON-demo Support-Ticket adopter (driftwood,
  the freight vertical) inherits the chat offline-escalation dedupe backstop. The atomic
  one-ticket-per-chat guarantee is only real if EVERY adopter's schema carries the partial-
  unique index — not just demo's hand-written migration. This asserts driftwood's `fsk_ticket`
  actually has `fsk_ticket_chat_dedupe_idx`, UNIQUE and PARTIAL (external_id IS NOT NULL), so
  a future change that drops the vertical's migration fails here.
  """
  use Driftwood.DataCase, async: false

  test "driftwood inherits the framework chat-escalation dedupe index (UNIQUE + PARTIAL)" do
    %{rows: [[exists]]} =
      Driftwood.Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = $1)",
        ["fsk_ticket_chat_dedupe_idx"]
      )

    assert exists,
           "driftwood fsk_ticket is MISSING the framework partial-unique chat-escalation dedupe index"

    %{rows: [[indexdef]]} =
      Driftwood.Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE indexname = $1",
        ["fsk_ticket_chat_dedupe_idx"]
      )

    assert indexdef =~ "UNIQUE", "the dedupe index must be UNIQUE (the atomic backstop): #{indexdef}"
    assert indexdef =~ "fsk_external_id IS NOT NULL",
           "the dedupe index must be PARTIAL so normal tickets are unconstrained: #{indexdef}"
  end
end
