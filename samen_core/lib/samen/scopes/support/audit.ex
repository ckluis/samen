defmodule Samen.Scopes.Support.Audit do
  @moduledoc """
  Audit writers for the Support scope (T3.6).

  A scope NEVER defines its own audit table (scope-authoring guide §6).
  This module writes token-only rows to the existing `aud_event` tier (T2.2:
  append-only, partitioned, REVOKE+trigger-guarded) via `Samen.AuditEvent.insert/2`.

  ## Signature

  All writers take `(repo, ticket_or_entity, actor_id)` where `repo` is the Ecto
  repo that owns the `aud_event` table. This mirrors `Samen.Scopes.Identity.Audit`
  and decouples the writers from config resolution (the caller owns the repo).

  ## Written events

  | event_type                     | subject_id   | detail                                  |
  |--------------------------------|--------------|-----------------------------------------|
  | `support.ticket.created`       | ticket.id    | `"priority=… status=… sla_id=…"`        |
  | `support.ticket.breached`      | ticket.id    | `"breach_at=<iso8601>"`                 |
  | `support.agent.created`        | agent.id     | `"role=…"` (NO name/email — PII!)       |
  | `support.csat.created`         | csat.id      | `"score=… ticket_id=…"`                 |

  ## Token-only discipline

  All `detail` strings carry ONLY opaque IDs, bounded enums, and numbers — never
  subject name/email/body PII. The `aud_subject_id` and `aud_actor_id` fields carry
  UUIDs/tokens. The `no_plaintext_pii` oracle enforces this on the `aud_event` tier
  at every CI run.
  """

  @doc """
  Emit a `support.ticket.created` event.

  `ticket` must have `:id`, `:org_id`, `:priority`, `:status` fields (standard ticket struct).
  `actor_id` is the creating actor's opaque UUID (or nil for system actions).
  """
  @spec ticket_created(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def ticket_created(repo, ticket, actor_id) do
    detail =
      "priority=#{ticket[:priority] || :normal} " <>
        "status=#{ticket[:status] || :open} " <>
        "sla_id=#{ticket[:sla_id] || "none"}"

    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(ticket.id),
      actor_id: actor_id,
      correlation_id: ticket.org_id,
      detail: "support.ticket.created #{detail}"
    })
  end

  @doc """
  Emit a `support.ticket.breached` event (fired by SlaBreachWorker).

  `ticket` must have `:id`, `:org_id` fields. `breach_at_iso` is the ISO-8601
  string of the SLA deadline — opaque enough for the audit tier.
  """
  @spec ticket_breached(module(), map(), String.t()) :: {:ok, term()} | {:error, term()}
  def ticket_breached(repo, ticket, breach_at_iso) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(ticket.id),
      actor_id: nil,
      correlation_id: ticket[:org_id],
      detail: "support.ticket.breached breach_at=#{breach_at_iso}"
    })
  end

  @doc """
  Emit a `support.agent.created` event.

  Note: the detail carries NO name/email (those are 🔒 PII vault-routed on the agent row).
  Only the bounded `role` enum is included.
  """
  @spec agent_created(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def agent_created(repo, agent, actor_id) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(agent.id),
      actor_id: actor_id,
      correlation_id: agent.org_id,
      detail: "support.agent.created role=#{agent[:role] || :agent}"
    })
  end

  @doc """
  Emit a `support.csat.created` event.

  Detail carries the score (a number — safe) and opaque ticket_id.
  """
  @spec csat_created(module(), map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def csat_created(repo, csat, actor_id) do
    Samen.AuditEvent.insert(repo, %{
      event_type: "system",
      subject_id: to_string(csat.id),
      actor_id: actor_id,
      correlation_id: csat.org_id,
      detail: "support.csat.created score=#{csat.score} ticket_id=#{csat[:ticket_id]}"
    })
  end
end
