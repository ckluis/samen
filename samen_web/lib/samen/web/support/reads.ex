defmodule Samen.Web.Support.Reads do
  @moduledoc """
  The framework Support read layer for the inherited Support pages (tickets, ticket detail).

  Promoted from the driftwood-local `Driftwood.SupportReads` (ADR-009 §3.3): resource + repo
  come from `Samen.Web.Mount`. PII fields:

    * Support `Agent` — full_name (composite vault) + email (scalar vault);
    * Support `Message` — body (scalar vault, free-text);

  resolved through `Samen.Api.PiiResolution.resolve/4` (tenant CLEAR / operator ••••).

  ## MASKING INVARIANT

  Never calls `Samen.Vault.reveal/3`, never unwraps a `%Masked{}`, never has a
  "show plaintext" branch. Plaintext only reaches the LiveView if the resolver resolved it
  through the shared chokepoint.
  """

  require Ash.Query

  alias Samen.Web.Mount

  @doc "Read all support tickets for `scope`, newest-first. Non-PII header."
  def tickets(mount, scope) do
    Mount.resource(mount, Ticket)
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

  @doc "Read a single ticket by id for `scope`. `{:ok, ticket}` or `:error`."
  def get_ticket(mount, scope, id) do
    result =
      Mount.resource(mount, Ticket)
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

  @doc "Read conversations (+ PII-resolved messages) for a ticket."
  def conversations_for_ticket(mount, scope, ticket_id) do
    convs =
      Mount.resource(mount, Conversation)
      |> Ash.Query.ensure_selected([:channel, :status, :subject, :ticket_id])
      |> Ash.Query.filter(ticket_id == ^ticket_id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.read!(scope: scope)

    agents_map = agents_by_id(mount, scope)

    Enum.map(convs, fn conv ->
      msgs = messages_for_conversation(mount, scope, conv.id, agents_map)
      Map.put(conv, :__messages__, msgs)
    end)
  rescue
    _ -> []
  end

  @doc "Read messages for a conversation with body PII-resolved and agent joined."
  def messages_for_conversation(mount, scope, conversation_id, agents_map \\ nil) do
    msgs =
      Mount.resource(mount, Message)
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
      |> resolve_pii(mount, Message, scope)

    agents_map = agents_map || agents_by_id(mount, scope)

    Enum.map(msgs, fn msg ->
      agent = agents_map[msg.agent_id]
      Map.put(msg, :__agent__, agent)
    end)
  rescue
    _ -> []
  end

  @doc "Read all support agents for `scope` with full_name/email PII-resolved."
  def agents(mount, scope) do
    Mount.resource(mount, Agent)
    |> Ash.Query.ensure_selected([:handle, :status, :role, :full_name, :email, :timezone])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Agent, scope)
  rescue
    _ -> []
  end

  @doc "agent_id → agent (PII-resolved) map for joining agent PII to messages/tickets."
  def agents_by_id(mount, scope) do
    agents(mount, scope) |> Map.new(&{&1.id, &1})
  end

  @doc "Read all CSAT responses for `scope`. Non-PII."
  def csats(mount, scope) do
    Mount.resource(mount, Csat)
    |> Ash.Query.ensure_selected([:score, :comments, :channel, :responded_at, :ticket_id, :agent_id])
    |> Ash.Query.sort(responded_at: :desc)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Non-PII support metrics (open_tickets, breaching_sla, solved_this_week, csat_avg)."
  def metrics(mount, scope) do
    %{
      open_tickets: count_open_tickets(mount, scope),
      breaching_sla: count_breaching(mount, scope),
      solved_this_week: count_solved_this_week(mount, scope),
      csat_avg: avg_csat(mount, scope)
    }
  end

  # -- private -----------------------------------------------------------------

  defp resolve_pii(records, mount, name, scope) do
    Samen.Api.PiiResolution.resolve(
      records,
      Mount.resource(mount, name),
      actor_of(scope),
      repo: mount.repo
    )
  rescue
    _ -> records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp count_open_tickets(mount, scope) do
    Mount.resource(mount, Ticket)
    |> Ash.Query.filter(status == :open)
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  defp count_breaching(mount, scope) do
    Mount.resource(mount, Ticket)
    |> Ash.Query.filter(breached == true and status not in [:resolved, :closed])
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  defp count_solved_this_week(mount, scope) do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)

    Mount.resource(mount, Ticket)
    |> Ash.Query.filter(status in [:resolved, :closed] and resolved_at >= ^week_ago)
    |> Ash.count!(scope: scope)
  rescue
    _ -> 0
  end

  defp avg_csat(mount, scope) do
    case csats(mount, scope) do
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
