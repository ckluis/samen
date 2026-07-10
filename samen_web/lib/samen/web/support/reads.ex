defmodule Samen.Web.Support.Reads do
  @moduledoc """
  The framework Support read layer for the inherited Support pages (tickets, ticket detail).

  Promoted from the driftwood-local `Driftwood.SupportReads` (ADR-009 §3.3): resource + repo
  come from `Samen.Web.Mount`. PII fields:

    * Support `Agent` — full_name (composite vault) + email (scalar vault);
    * Support `Message` — body (scalar vault, free-text);

  resolved through `Samen.Api.PiiResolution.resolve/4` (tenant CLEAR / operator ••••).

  ## A3 read-bounding (WS-A design §1.1 "read! elimination")

  The Ticket Inbox reads through the paginated `tickets_page/3` (built on
  `Samen.Web.Reads.page!/3` — BOUNDED BY CONSTRUCTION); every remaining detail /
  lookup read carries an explicit `limit(#{200})` (single-parent fan-outs, not hot
  lists). Metrics are DB aggregates (`Ash.count`/`Ash.avg`) — no row set transferred.

  ## A3 write side (sanctioned domain actions only)

  The support blueprint defines `defaults([:read, :destroy, create: :*, update: :*])`;
  this module only exposes those: ticket create/delete (member-gated by the kernel),
  the bounded ticket STATUS update, and the message (reply) create — whose vaulted
  `body` rides `Samen.Vault.Change` (MC-2) and is refused to an operator-plane actor
  by `Samen.Pii.WriteGuard` (MC-1) at the Ash write path.

  ## MASKING INVARIANT

  Never calls `Samen.Vault.reveal/3`, never unwraps a `%Masked{}`, never has a
  "show plaintext" branch. Plaintext only reaches the LiveView if the resolver resolved it
  through the shared chokepoint.
  """

  require Ash.Query

  alias Samen.Web.Mount

  # Bounded detail/lookup reads (a ticket's conversations, a conversation's messages,
  # the agent join map). Single-parent fan-outs, not hot lists.
  @detail_limit 200

  # The blueprint's bounded status enum — client input is matched against THIS list,
  # never atomized (`String.to_atom/1` on client input mints atoms).
  @ticket_statuses [:open, :pending, :on_hold, :resolved, :closed]

  @doc "The bounded ticket status set (the blueprint's `one_of` — the status select's options)."
  def ticket_statuses, do: @ticket_statuses

  @doc """
  Read support tickets for `scope`, newest-first. Non-PII header. BOUNDED to
  #{@detail_limit} rows (A3 read-bounding); the Ticket Inbox itself reads through the
  paginated `tickets_page/3`.
  """
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
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Read ONE keyset page of support tickets for `scope` — the `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`, ADR-016 §3), built on
  `Samen.Web.Reads.page!/3` so the read is BOUNDED BY CONSTRUCTION. The ticket header
  is non-PII; sort/filter fields are bounded plain attributes (`subject` is freeform
  ticket text but NOT vaulted — and it is default-denied from the CDC projection, see
  the A1 classifier). On any read error the page is EMPTY — never unbounded.
  """
  def tickets_page(mount, scope, state) do
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
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:subject])
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
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
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)

    case result do
      [ticket | _] -> {:ok, ticket}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Read conversations (+ PII-resolved messages) for a ticket. BOUNDED."
  def conversations_for_ticket(mount, scope, ticket_id) do
    convs =
      Mount.resource(mount, Conversation)
      |> Ash.Query.ensure_selected([:channel, :status, :subject, :ticket_id])
      |> Ash.Query.filter(ticket_id == ^ticket_id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)

    agents_map = agents_by_id(mount, scope)

    Enum.map(convs, fn conv ->
      msgs = messages_for_conversation(mount, scope, conv.id, agents_map)
      Map.put(conv, :__messages__, msgs)
    end)
  rescue
    _ -> []
  end

  @doc "Read messages for a conversation with body PII-resolved and agent joined. BOUNDED."
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
      |> Ash.Query.limit(@detail_limit)
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

  @doc "Read support agents for `scope` with full_name/email PII-resolved. BOUNDED."
  def agents(mount, scope) do
    Mount.resource(mount, Agent)
    |> Ash.Query.ensure_selected([:handle, :status, :role, :full_name, :email, :timezone])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Agent, scope)
  rescue
    _ -> []
  end

  @doc "agent_id → agent (PII-resolved) map for joining agent PII to messages/tickets."
  def agents_by_id(mount, scope) do
    agents(mount, scope) |> Map.new(&{&1.id, &1})
  end

  @doc "Read CSAT responses for `scope`. Non-PII. BOUNDED to #{@detail_limit} rows."
  def csats(mount, scope) do
    Mount.resource(mount, Csat)
    |> Ash.Query.ensure_selected([:score, :comments, :channel, :responded_at, :ticket_id, :agent_id])
    |> Ash.Query.sort(responded_at: :desc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc """
  Non-PII support metrics (open_tickets, breaching_sla, solved_this_week, csat_avg).
  DB aggregates (`Ash.count`/`Ash.avg`) — no row set is ever transferred (A3
  read-bounding: this replaced an unbounded CSAT `read!`).
  """
  def metrics(mount, scope) do
    %{
      open_tickets: count_open_tickets(mount, scope),
      breaching_sla: count_breaching(mount, scope),
      solved_this_week: count_solved_this_week(mount, scope),
      csat_avg: avg_csat(mount, scope)
    }
  end

  # -- A3 write side (sanctioned defaults only) ----------------------------------

  @doc """
  Create a support message (the ticket REPLY / internal note composer). `attrs`
  carries `conversation_id` (a server-side fact from the detail page, never client
  input), `body` (🔒 vault-routed — MC-2 on the tenant plane; REFUSED to an
  operator-plane actor by `Samen.Pii.WriteGuard`, MC-1), `sender_type`,
  `message_type`, and `org_id`. The write goes through Ash so OrgScope + SameOrgFk
  apply — this module adds NO policy of its own. `{:ok, message}` or `{:error, form}`.
  """
  def create_message(mount, scope, attrs) do
    Mount.resource(mount, Message)
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create()
  end

  @doc """
  Update a ticket's STATUS (the sanctioned `update: :*` — "ticket status" per the A3
  wiring scope). `status` is a STRING matched against the bounded blueprint enum
  (`ticket_statuses/0`) — client input never mints an atom; an unknown status is
  refused as `{:error, :invalid_status}`. `{:ok, ticket}` or `{:error, reason}`.
  """
  def update_ticket_status(mount, scope, id, status) when is_binary(status) do
    case Enum.find(@ticket_statuses, fn s -> Atom.to_string(s) == status end) do
      nil -> {:error, :invalid_status}
      bounded -> update_ticket_status(mount, scope, id, bounded)
    end
  end

  def update_ticket_status(mount, scope, id, status) when status in @ticket_statuses do
    record =
      Mount.resource(mount, Ticket)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil ->
        {:error, :not_found}

      ticket ->
        ticket
        |> Ash.Changeset.for_update(:update, %{status: status}, scope: scope)
        |> Ash.update()
    end
  rescue
    e -> {:error, e}
  end

  @doc "Destroy one support ticket for `scope` (A3 CRUD wiring). `:ok` or `{:error, reason}`."
  def delete_ticket(mount, scope, id) do
    record =
      Mount.resource(mount, Ticket)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> {:error, :not_found}
      ticket -> Ash.destroy(ticket, scope: scope)
    end
  rescue
    e -> {:error, e}
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
    case Ash.avg!(Mount.resource(mount, Csat), :score, scope: scope) do
      nil -> nil
      avg when is_float(avg) -> Float.round(avg, 1)
      avg -> avg |> Decimal.to_float() |> Float.round(1)
    end
  rescue
    _ -> nil
  end
end
