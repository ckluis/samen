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
  alias Samen.Web.Reads.Guard

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
  def tickets(mount, scope), do: tickets_result(mount, scope) |> Guard.value([])

  @doc """
  Tagged sibling of `tickets/2` (WP6): `{:ok, value}`, or `{:error, :unavailable}` when the read FAILED (an outage is not an empty result), or `{:error, :forbidden}` for a denial.
  """
  def tickets_result(mount, scope) do
    Guard.run(:support_tickets, scope, fn ->
      Mount.resource(mount, Ticket)
      |> Ash.Query.ensure_selected([
        :subject,
        :status,
        :priority,
        :sla_breach_at,
        :breached,
        :resolved_at,
        :sla_id
      ])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
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
    Guard.page(:support_tickets_page, scope, state, fn ->
      Mount.resource(mount, Ticket)
      |> Ash.Query.ensure_selected([
        :subject,
        :status,
        :priority,
        :sla_breach_at,
        :breached,
        :resolved_at,
        :sla_id
      ])
      |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:subject])
    end)
  end

  @doc "Read a single ticket by id for `scope`. `{:ok, ticket}` or `:error`."
  def get_ticket(mount, scope, id) do
    case get_ticket_result(mount, scope, id) do
      {:ok, ticket} -> {:ok, ticket}
      {:error, _kind} -> :error
    end
  end

  @doc """
  Tagged sibling of `get_ticket/3` (WP6): `{:ok, ticket}`, `{:error, :not_found}` for a missing
  (or malformed / denied) id, and `{:error, :unavailable}` when the read FAILED — an outage is
  not "Ticket not found".
  """
  def get_ticket_result(mount, scope, id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, rows} <-
           Guard.run(:support_get_ticket, scope, fn ->
             Mount.resource(mount, Ticket)
             |> Ash.Query.ensure_selected([
               :subject,
               :status,
               :priority,
               :sla_breach_at,
               :breached,
               :resolved_at,
               :sla_id
             ])
             |> Ash.Query.filter(id == ^uuid)
             |> Ash.Query.limit(1)
             |> Ash.read!(scope: scope)
           end) do
      case rows do
        [ticket | _] -> {:ok, ticket}
        [] -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      {:error, :unavailable} = unavailable -> unavailable
    end
  end

  @doc """
  Read tag NAMES for one ticket (F4/T46 — the generic-Tag-backed read
  equivalent of the former `Ticket.tags` array column). Derives the ticket's
  object-ref key via `ObjectRef.Catalog.key_for/1` (host-agnostic — matches
  whatever the host's `MigrateTicketTagsToTagScope` migration anchored, e.g.
  `"support.ticket"` on driftwood/pawchart/samen_web, `"support_scope.ticket"`
  on demo) and looks up `Samen.Web.Tags.names_for/4`. Fails safe to `[]` if the
  host has not mounted the Tags scope — never raises.
  """
  def ticket_tag_names(mount, scope, ticket_id),
    do: ticket_tag_names_result(mount, scope, ticket_id) |> Guard.value([])

  @doc "Tagged sibling of `ticket_tag_names/3` (WP6): `{:ok, names}` or `{:error, :unavailable | :forbidden}` — a failed read is not 'untagged'."
  def ticket_tag_names_result(mount, scope, ticket_id) do
    subject_key = Samen.Web.ObjectRef.Catalog.key_for(Mount.resource(mount, Ticket))
    Samen.Web.Tags.names_for_result(mount, scope, subject_key, ticket_id)
  end

  @doc "Read conversations (+ PII-resolved messages) for a ticket. BOUNDED."
  def conversations_for_ticket(mount, scope, ticket_id),
    do: conversations_for_ticket_result(mount, scope, ticket_id) |> Guard.value([])

  @doc """
  Tagged sibling of `conversations_for_ticket/3` (WP6): `{:ok, conversations}` (an EMPTY list is
  the honest "no thread yet") or `{:error, :unavailable}` — a failed read must never offer
  "Start conversation" (audit F08: it created duplicate conversations on a transient error).
  """
  def conversations_for_ticket_result(mount, scope, ticket_id) do
    Guard.run(:support_conversations_for_ticket, scope, fn ->
      convs =
        Mount.resource(mount, Conversation)
        |> Ash.Query.ensure_selected([:channel, :status, :subject, :ticket_id])
        |> Ash.Query.filter(ticket_id == ^ticket_id)
        |> Ash.Query.sort(inserted_at: :asc)
        |> Ash.Query.limit(@detail_limit)
        |> Ash.read!(scope: scope)

      agents_map = Map.new(agents!(mount, scope), &{&1.id, &1})

      Enum.map(convs, fn conv ->
        {msgs, truncated?} = messages_window!(mount, scope, conv.id, agents_map)

        conv
        |> Map.put(:__messages__, msgs)
        |> Map.put(:__earlier_hidden__, truncated?)
      end)
    end)
  end

  @doc """
  Read messages for a conversation with body PII-resolved and agent joined. BOUNDED to the
  NEWEST `#{@detail_limit}` messages, returned oldest-first.
  """
  def messages_for_conversation(mount, scope, conversation_id, agents_map \\ nil),
    do: elem(messages_window_for_conversation(mount, scope, conversation_id, agents_map), 0)

  @doc "Like `messages_for_conversation/4` but `{messages, earlier_hidden?}`."
  def messages_window_for_conversation(mount, scope, conversation_id, agents_map \\ nil) do
    mount
    |> messages_window_for_conversation_result(scope, conversation_id, agents_map)
    |> Guard.value({[], false})
  end

  @doc "Tagged sibling of `messages_window_for_conversation/4` (WP6): `{:ok, {messages, earlier_hidden?}}` or `{:error, :unavailable}`."
  def messages_window_for_conversation_result(mount, scope, conversation_id, agents_map \\ nil) do
    Guard.run(:support_messages_window, scope, fn -> messages_window!(mount, scope, conversation_id, agents_map) end)
  end

  # The raising read, for callers already inside a `Guard.run/3`.
  defp messages_window!(mount, scope, conversation_id, agents_map) do
    {rows, truncated?} =
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
      |> Samen.Web.Reads.newest_window(@detail_limit, scope: scope)

    msgs = resolve_pii(rows, mount, Message, scope)
    agents_map = agents_map || Map.new(agents!(mount, scope), &{&1.id, &1})

    {Enum.map(msgs, fn msg -> Map.put(msg, :__agent__, agents_map[msg.agent_id]) end), truncated?}
  end

  @doc "Read support agents for `scope` with full_name/email PII-resolved. BOUNDED."
  def agents(mount, scope), do: agents_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `agents/2` (WP6): `{:ok, agents}` or `{:error, :unavailable}`."
  def agents_result(mount, scope), do: Guard.run(:support_agents, scope, fn -> agents!(mount, scope) end)

  # The raising read, for callers already inside a `Guard.run/3`.
  defp agents!(mount, scope) do
    Mount.resource(mount, Agent)
    |> Ash.Query.ensure_selected([:handle, :status, :role, :full_name, :email, :timezone])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
    |> resolve_pii(mount, Agent, scope)
  end

  @doc "agent_id → agent (PII-resolved) map for joining agent PII to messages/tickets."
  def agents_by_id(mount, scope), do: agents(mount, scope) |> Map.new(&{&1.id, &1})

  @doc "Tagged sibling of `agents_by_id/2` (WP6)."
  def agents_by_id_result(mount, scope) do
    with {:ok, agents} <- agents_result(mount, scope), do: {:ok, Map.new(agents, &{&1.id, &1})}
  end

  @doc "Read CSAT responses for `scope`. Non-PII. BOUNDED to #{@detail_limit} rows."
  def csats(mount, scope), do: csats_result(mount, scope) |> Guard.value([])

  @doc """
  Tagged sibling of `csats/2` (WP6): `{:ok, value}`, or `{:error, :unavailable}` when the read FAILED (an outage is not an empty result), or `{:error, :forbidden}` for a denial.
  """
  def csats_result(mount, scope) do
    Guard.run(:support_csats, scope, fn ->
      Mount.resource(mount, Csat)
      |> Ash.Query.ensure_selected([:score, :comments, :channel, :responded_at, :ticket_id, :agent_id])
      |> Ash.Query.sort(responded_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc """
  I6 (spec §I6, T79) — the CSAT response for ONE ticket, if any (the ticket
  detail page's "somewhere honest" landing spot — see `csats/2` for the
  org-wide list). `nil` when no response has been recorded yet (honest empty,
  never a fabricated score). Org-scoped via `scope` — a cross-org `ticket_id`
  yields `nil`, never another org's response (no existence oracle).
  """
  def csat_for_ticket(mount, scope, ticket_id), do: csat_for_ticket_result(mount, scope, ticket_id) |> Guard.value(nil)

  @doc """
  Tagged sibling of `csat_for_ticket/3` (WP6): `{:ok, value}`, or `{:error, :unavailable}` when the read FAILED (an outage is not an empty result), or `{:error, :forbidden}` for a denial.
  """
  def csat_for_ticket_result(mount, scope, ticket_id) do
    Guard.run(:support_csat_for_ticket, scope, fn ->
      Mount.resource(mount, Csat)
      |> Ash.Query.ensure_selected([:score, :comments, :channel, :responded_at, :ticket_id, :agent_id])
      |> Ash.Query.filter(ticket_id == ^ticket_id)
      |> Ash.Query.sort(responded_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)
    end)
  end

  @doc """
  I6 (spec §I6, T79) — read org-scoped, ENABLED macros for the composer
  palette (Tier-0 config rows, `Sla`'s own sibling). Non-PII (the blueprint's
  own `body_template` non-PII classification). BOUNDED to #{@detail_limit}
  rows, sorted by name. Honest empty (`[]`) when the org has none — never
  fabricated.
  """
  def macros(mount, scope), do: macros_result(mount, scope) |> Guard.value([])

  @doc """
  Tagged sibling of `macros/2` (WP6): `{:ok, value}`, or `{:error, :unavailable}` when the read FAILED (an outage is not an empty result), or `{:error, :forbidden}` for a denial.
  """
  def macros_result(mount, scope) do
    Guard.run(:support_macros, scope, fn ->
      Mount.resource(mount, Macro)
      |> Ash.Query.filter(enabled == true)
      |> Ash.Query.ensure_selected([:name, :description, :body_template, :tags, :category])
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  # The macro composer palette's ONE placeholder: `{{agent_name}}`. `agents`
  # is `Reads.agents/2`'s ALREADY plane-resolved list (tenant CLEAR / operator
  # `%Masked{}`) — substitution never itself calls the vault or PiiResolution;
  # it just interpolates whatever the resolver already returned, via
  # `String.Chars` (a `%Masked{}` renders `••••` automatically — the SAME
  # convention `Samen.Delivery.Rendering.default_template/1` documents: "the
  # mask is the field's normal value, not a special case here"). `agents`
  # picks the FIRST loaded agent as "the" agent — a documented judgment call
  # (this framework has no per-agent login/session concept to derive a
  # "current agent" from, the same substrate limit `T76`'s CRM leaderboard
  # tile flagged for `owner_id` display identity).
  @doc """
  Expand `macro.body_template`'s `{{agent_name}}` placeholder (if present)
  against `agents` (a `Reads.agents/2`-shaped, ALREADY plane-resolved list —
  masking-safe by construction, no new vault call). Absent macro/agents ⇒ the
  template returned unexpanded (never crashes on `nil`).
  """
  def expand_macro(%{body_template: template}, agents) when is_binary(template) do
    String.replace(template, "{{agent_name}}", agent_name_placeholder(agents))
  end

  def expand_macro(_macro, _agents), do: ""

  defp agent_name_placeholder([%{full_name: full_name} | _]), do: to_string(render_agent_name_for_macro(full_name))
  defp agent_name_placeholder(_), do: "our team"

  defp render_agent_name_for_macro(%Samen.Masked{} = m), do: m
  defp render_agent_name_for_macro(name) when is_binary(name), do: decode_macro_full_name(name) || name
  defp render_agent_name_for_macro(_), do: "our team"

  defp decode_macro_full_name(name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> nil
    end
  end

  @doc """
  Non-PII support metrics (open_tickets, breaching_sla, solved_this_week, csat_avg).
  DB aggregates (`Ash.count`/`Ash.avg`) — no row set is ever transferred (A3
  read-bounding: this replaced an unbounded CSAT `read!`).
  """
  def metrics(mount, scope) do
    {stats, _failed} = metrics_status(mount, scope)
    stats
  end

  @doc """
  `metrics/2` plus WHICH of its four numbers could not be read (WP6): `{stats, failed}`, `failed`
  a subset of `[:open_tickets, :breaching_sla, :solved_this_week, :csat_avg]`. A failed number
  keeps its legacy value (`0` / `nil`) in `stats` but is named in `failed`, so a tile shows an
  error instead of a confident zero. Each number is its own guarded read.
  """
  def metrics_status(mount, scope) do
    week_ago = DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
    tickets = fn -> Mount.resource(mount, Ticket) end

    parts = [
      open_tickets:
        {Guard.run(:support_metric_open_tickets, scope, fn ->
           tickets.() |> Ash.Query.filter(status == :open) |> Ash.count!(scope: scope)
         end), 0},
      breaching_sla:
        {Guard.run(:support_metric_breaching_sla, scope, fn ->
           tickets.()
           |> Ash.Query.filter(breached == true and status not in [:resolved, :closed])
           |> Ash.count!(scope: scope)
         end), 0},
      solved_this_week:
        {Guard.run(:support_metric_solved_this_week, scope, fn ->
           tickets.()
           |> Ash.Query.filter(status in [:resolved, :closed] and resolved_at >= ^week_ago)
           |> Ash.count!(scope: scope)
         end), 0},
      csat_avg: {Guard.run(:support_metric_csat_avg, scope, fn -> avg_csat!(mount, scope) end), nil}
    ]

    {Map.new(parts, fn {key, {result, default}} -> {key, Guard.value(result, default)} end),
     for({key, {result, _default}} <- parts, Guard.unavailable?(result), do: key)}
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
  Start a NEW conversation on a ticket (the "Start conversation" first-reply
  affordance, H4/M3 — a UI-created ticket seeds no conversation of its own, so
  `new_reply_form/3` has nothing to build a composer against). `ticket_id` is a
  server-side fact (the current ticket, never client input); the created
  conversation takes the blueprint's default `:email` channel / `:open` status.
  The write goes through Ash so OrgScope + SameOrgFk apply — this module adds NO
  policy of its own. `{:ok, conversation}` or `{:error, reason}`.
  """
  def create_conversation(mount, scope, ticket_id) do
    org_id = Map.get(actor_of(scope), :org_id)

    Mount.resource(mount, Conversation)
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, ticket_id: ticket_id}, scope: scope)
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

  @doc """
  Archive one support ticket for `scope` (A3 CRUD wiring). `:ok` or `{:error, reason}`.

  ADR-040 §5.9/T37f: `Ticket` is `archivable true` and the cascade PARENT of `ticket
  ▸cascade conversation ▸cascade message` (§5.4). Routes through the explicit `:archive`
  action (not the plain default destroy) so the cascade engages —
  `Samen.Scopes.Support.CascadeArchive` self-guards on the `:archive` action name
  specifically (mirroring `Samen.Scopes.Cms.CascadeArchive`'s convention: the plain soft
  destroy does NOT cascade, only the explicit audited `:archive` does). A ticket with
  linked conversations/messages is therefore no longer refused — it archives, and its
  conversations/messages archive with it at the same instant, dropping all of them out of
  their default (archived-excluding) bounded reads. Any `{:error, _}` here is a genuine
  failure (e.g. an authorization denial), not the old FK-refusal case.
  """
  def delete_ticket(mount, scope, id) do
    record =
      Mount.resource(mount, Ticket)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> {:error, :not_found}
      ticket -> Ash.destroy(ticket, action: :archive, scope: scope)
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
    e ->
      # Fail-closed (no plaintext downgrade), but not silent: a resolver outage is logged.
      Guard.report(:support_resolve_pii, scope, e)
      records
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}

  defp avg_csat!(mount, scope) do
    case Ash.avg!(Mount.resource(mount, Csat), :score, scope: scope) do
      nil -> nil
      avg when is_float(avg) -> Float.round(avg, 1)
      avg -> avg |> Decimal.to_float() |> Float.round(1)
    end
  end
end
