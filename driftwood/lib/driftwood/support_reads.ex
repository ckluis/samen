defmodule Driftwood.SupportReads do
  @moduledoc """
  The Support read layer for the inherited Support pages
  (/support, /support/tickets/:id).

  All reads go through Ash so OrgScope + vault masking apply. PII fields:

    * `Driftwood.Support.Agent` — full_name (composite vault :pii_name) and
      email (scalar vault :pii_email) — resolved through
      `Samen.Api.PiiResolution.resolve/4`.
    * `Driftwood.Support.Message` — body (scalar vault :pii_body) — resolved
      through `Samen.Api.PiiResolution.resolve/4`.

  Plane semantics:
    * `plane: :tenant` — the org reads its OWN agents' PII and message bodies
      in CLEAR (tenant-as-owner rule; §external-surface :707).
    * `plane: :operator` (impersonation) — the SAME fields render `%Masked{}`
      (→ ••••) by construction of the resolver.

  ## MASKING INVARIANT

  This module NEVER calls `Samen.Vault.reveal/3`, NEVER pattern-matches a
  vault token out of a `%Masked{}`, and NEVER introduces a "show plaintext"
  code path. Plaintext only reaches the LiveView if the PiiResolution resolver
  already resolved it through the shared chokepoint.
  """

  require Ash.Query

  # ---------------------------------------------------------------------------
  # Tickets
  # ---------------------------------------------------------------------------

  @doc """
  Read all support tickets for the given scope, sorted newest-first.

  Returns a list of `Driftwood.Support.Ticket` structs. No PII on the ticket
  header (subject, status, priority, sla_breach_at, breached, tags). Agents
  resolved separately via `agents_by_id/1`.
  """
  def tickets(scope) do
    Driftwood.Support.Ticket
    |> Ash.Query.ensure_selected([
      :subject,
      :status,
      :priority,
      :sla_breach_at,
      :breached,
      :resolved_at,
      :tags,
      :sla_id
    ])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read a single ticket by id for the given scope.

  Returns `{:ok, ticket}` or `:error`.
  """
  def get_ticket(scope, id) do
    result =
      Driftwood.Support.Ticket
      |> Ash.Query.ensure_selected([
        :subject,
        :status,
        :priority,
        :sla_breach_at,
        :breached,
        :resolved_at,
        :tags,
        :sla_id
      ])
      |> Ash.Query.filter(id == ^id)
      |> Ash.read!(scope: scope)

    case result do
      [ticket | _] -> {:ok, ticket}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  # ---------------------------------------------------------------------------
  # Conversations + Messages (PII: message body)
  # ---------------------------------------------------------------------------

  @doc """
  Read conversations (and their messages) for a ticket.

  Returns a list of conversation structs, each carrying a `__messages__` key
  with messages resolved through PiiResolution (body may be %Masked{}).
  """
  def conversations_for_ticket(scope, ticket_id) do
    convs =
      Driftwood.Support.Conversation
      |> Ash.Query.ensure_selected([:channel, :status, :subject, :ticket_id])
      |> Ash.Query.filter(ticket_id == ^ticket_id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)

    agents_map = agents_by_id(scope)

    Enum.map(convs, fn conv ->
      msgs = messages_for_conversation(scope, conv.id, agents_map)
      Map.put(conv, :__messages__, msgs)
    end)
  rescue
    _ -> []
  end

  @doc """
  Read all messages for a conversation, with body resolved via PiiResolution
  and agent PII resolved inline.

  Returns a list of message structs with `:body` plane-resolved and
  `:__agent__` (agent struct with PII resolved, or nil if system/customer).
  """
  def messages_for_conversation(scope, conversation_id, agents_map \\ nil) do
    msgs =
      Driftwood.Support.Message
      |> Ash.Query.ensure_selected([
        :sender_type,
        :sender_id,
        :message_type,
        :created_via,
        :conversation_id,
        :agent_id,
        :body
      ])
      |> Ash.Query.filter(conversation_id == ^conversation_id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)
      |> resolve_message_pii(scope)

    agents_map = agents_map || agents_by_id(scope)

    Enum.map(msgs, fn msg ->
      agent = agents_map[msg.agent_id]
      Map.put(msg, :__agent__, agent)
    end)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Agents (PII: full_name + email)
  # ---------------------------------------------------------------------------

  @doc """
  Read all support agents for the given scope with PII resolved.

  Returns a list of `Driftwood.Support.Agent` structs with
  `full_name` / `email` plane-resolved.
  """
  def agents(scope) do
    Driftwood.Support.Agent
    |> Ash.Query.ensure_selected([:handle, :status, :role, :full_name, :email, :timezone])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_agent_pii(scope)
  rescue
    _ -> []
  end

  @doc """
  Returns a map of agent_id → agent (with PII resolved) for efficient lookup.
  Used internally when joining agent PII to messages / tickets.
  """
  def agents_by_id(scope) do
    agents(scope)
    |> Map.new(&{&1.id, &1})
  end

  # ---------------------------------------------------------------------------
  # CSAT
  # ---------------------------------------------------------------------------

  @doc """
  Read all CSAT responses for the given scope. No PII on csat itself.
  """
  def csats(scope) do
    Driftwood.Support.Csat
    |> Ash.Query.ensure_selected([:score, :comments, :channel, :responded_at, :ticket_id, :agent_id])
    |> Ash.Query.sort(responded_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Metrics
  # ---------------------------------------------------------------------------

  @doc """
  Support metrics for the summary cards on /support:
    * open_tickets     — count of tickets with status :open
    * breaching_sla    — count of tickets that are breached (breached == true) and not resolved
    * solved_this_week — count of tickets resolved in the last 7 days
    * csat_avg         — average CSAT score (nil if no responses)

  All non-PII. An error in one metric returns a safe default (0 or nil).
  """
  def metrics(scope) do
    open_tickets = count_open_tickets(scope)
    breaching_sla = count_breaching(scope)
    solved_this_week = count_solved_this_week(scope)
    csat_avg = avg_csat(scope)

    %{
      open_tickets: open_tickets,
      breaching_sla: breaching_sla,
      solved_this_week: solved_this_week,
      csat_avg: csat_avg
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Resolve PII fields on Message records (body) via the shared resolver.
  # Fail-safe: on any resolver error the body stays %Masked{}.
  defp resolve_message_pii(records, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Driftwood.Support.Message,
      actor_of(scope),
      repo: Driftwood.Repo
    )
  rescue
    _ -> records
  end

  # Resolve PII fields on Agent records (full_name / email) via the shared resolver.
  # Fail-safe: on any resolver error the fields stay %Masked{}.
  defp resolve_agent_pii(records, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Driftwood.Support.Agent,
      actor_of(scope),
      repo: Driftwood.Repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp count_open_tickets(scope) do
    Driftwood.Support.Ticket
    |> Ash.Query.filter(status == :open)
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  defp count_breaching(scope) do
    Driftwood.Support.Ticket
    |> Ash.Query.filter(breached == true and status not in [:resolved, :closed])
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  defp count_solved_this_week(scope) do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    Driftwood.Support.Ticket
    |> Ash.Query.filter(status in [:resolved, :closed] and resolved_at >= ^week_ago)
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  defp avg_csat(scope) do
    csats_list = csats(scope)

    case csats_list do
      [] ->
        nil

      scores ->
        total = Enum.reduce(scores, 0, &((&1.score || 0) + &2))
        Float.round(total / length(scores), 1)
    end
  rescue
    _ -> nil
  end
end
