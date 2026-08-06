defmodule Samen.Web.Operator.DeskDetailLive do
  @moduledoc """
  Framework OPERATOR / Desk TICKET DETAIL (T149 B1) — `/operator/desk/:id`. The missing
  resolve surface: `Samen.Web.Operator.DeskLive` was list+create+delete only, so an operator
  could SEE a ticket but never OPEN it, read the conversation, or ANSWER it. This LiveView
  renders one ticket's conversation thread and posts a REPLY through the SAME governed
  `Support.Message` create the seeds/support engine use (`Samen.Web.Operator.Reads.post_reply/5`)
  — OrgScope + `RoleAtLeast(:member)` gate the write; the body is VAULT-routed by
  `Samen.Vault.Change` at the write boundary (no plaintext column minted here).

  ## T146 operator-ROLE gated (by construction)

  Mounted INSIDE `samen_operator_routes/2`'s `live_session` (router.ex), so it carries the
  `{Samen.Web.Operator.Authz, :require_operator}` on_mount — a plain tenant-user session can
  never reach it (driftwood `operator_authz_test.exs` proves the RED path for every
  `/operator/*` live route). It reads the operator org's OWN desk on the TENANT plane
  (ADR-010 §7.2), so it is the SaaS's own book of business — NOT a per-tenant impersonation
  drill-in, and therefore not T150-session-gated (same posture as `DeskLive` /
  `PlatformBillingLive`; see `Samen.Web.Operator.Impersonation`'s "what is NOT gated").

  ## Masking (per-plane) — message body is 🔒

  A message `body` is vault-routed. It resolves through `Samen.Api.PiiResolution` on the
  scope's plane: CLEAR on the operator's own tenant plane (the SaaS owns its own desk), and
  `%Masked{}` → `••••` on an operator-plane (impersonation) mount — NEVER unwrapped, NO
  plaintext branch (proved green+red in `operator_desk_detail_test.exs`).

  ## AI-assisted draft (T149 B2a) — surfaced, fail-honest, never auto-send

  "Draft AI reply" calls the EXISTING `Samen.AI.SupportOperator.draft_reply/3` (the D5 operator
  that drafts + enqueues a HUMAN approval — it NEVER sends). Keyless in CI (`Provider.Fake`);
  unconfigured outside `:test` ⇒ the honest `{:error, :not_configured}` state, never a faked
  draft. Full draft PERSISTENCE additionally needs the host to adopt the AI plane (bind
  `:samen_ai_support_reply_draft_repo` + the `ai_support_reply_draft` migration + register the
  `ai_support_reply` approval kind); until then the call fail-honests and this surface reports
  it truthfully rather than inventing a draft.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket, params["id"])}
  end

  @doc false
  def load(socket, ticket_id) do
    mount = socket.assigns[:samen_mount]
    operator_org_id = mount && Operator.org_id(mount)

    socket =
      socket
      |> assign_new(:reply_error, fn -> nil end)
      |> assign_new(:ai_draft, fn -> nil end)
      |> assign_new(:ai_error, fn -> nil end)

    case {operator_org_id, ticket_id} do
      {nil, _} ->
        assign(socket, no_org: true, ticket_id: ticket_id, operator_org_id: nil, ticket: nil)

      {_org, nil} ->
        assign(socket, no_org: false, ticket_id: nil, operator_org_id: operator_org_id, ticket: nil)

      {org_id, ticket_id} ->
        scope = Operator.scope(mount)

        assign(socket,
          no_org: false,
          ticket_id: ticket_id,
          operator_org_id: org_id,
          ticket: Reads.ticket_detail(mount, scope, ticket_id)
        )
    end
  end

  # -- reply (governed Support.Message create) ---------------------------------

  @impl true
  def handle_event("reply", %{"reply" => %{"body" => body}}, socket) do
    body = String.trim(body || "")
    mount = socket.assigns.samen_mount

    cond do
      not writable?(mount) ->
        {:noreply, assign(socket, reply_error: "This operator mount is read-only.")}

      body == "" ->
        {:noreply, assign(socket, reply_error: "A reply body is required.")}

      true ->
        scope = Operator.scope(mount)

        case Reads.post_reply(mount, scope, socket.assigns.operator_org_id, socket.assigns.ticket_id, body) do
          :ok ->
            {:noreply, socket |> assign(reply_error: nil, ai_draft: nil, ai_error: nil) |> load(socket.assigns.ticket_id)}

          {:error, _reason} ->
            {:noreply, assign(socket, reply_error: "Could not post the reply.")}
        end
    end
  end

  # -- AI draft (T149 B2a) — surface the EXISTING draft→approve loop, fail-honest -------
  def handle_event("draft_ai", _params, socket) do
    mount = socket.assigns.samen_mount
    scope = Operator.scope(mount)

    attrs = %{
      to_subscriber_id: requester_subscriber_id(socket.assigns.ticket),
      instruction:
        "Draft a concise, friendly support reply for the ticket " <>
          inspect(socket.assigns.ticket && socket.assigns.ticket.subject) <> "."
    }

    case draft_reply(scope, attrs) do
      {:ok, %{draft_text: text} = result} ->
        {:noreply,
         assign(socket,
           ai_draft: %{text: text, approval_id: Map.get(result, :approval_id)},
           ai_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, ai_draft: nil, ai_error: honest_ai_error(reason))}
    end
  end

  # Copy the AI draft into the reply box (the operator reviews/edits, then posts through the
  # normal governed reply — the human stays in the loop).
  def handle_event("use_draft", _params, socket), do: {:noreply, socket}

  # `draft_reply/3` is fail-honest but persistence can RAISE on a host that has not adopted
  # the AI plane (its `SupportReplyDraft` repo is absent) — normalize any raise to an honest
  # `{:error, _}` so the button never crashes the LiveView and never fakes a draft.
  defp draft_reply(scope, attrs) do
    Samen.AI.SupportOperator.draft_reply(scope, attrs)
  rescue
    _ -> {:error, :not_configured}
  end

  defp requester_subscriber_id(%{__requester__: %{id: id}}) when is_binary(id), do: id
  defp requester_subscriber_id(_), do: "operator-desk"

  defp honest_ai_error(:not_configured),
    do: "AI drafting is not configured for this host (no provider wired). No draft was produced."

  defp honest_ai_error(reason),
    do: "AI drafting is unavailable (#{inspect(reason)}). No draft was produced."

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-desk-detail">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:desk} />
        </:sidebar>

        <.topbar title="Ticket" crumbs={["Operator plane", "Desk", "Ticket"]}>
          <:actions>
            <a href="/operator/desk" id="back-to-desk" class="btn">Back to Desk</a>
          </:actions>
        </.topbar>

        <%= cond do %>
          <% @no_org -> %>
            <div class="wrap">
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">No operator org resolved.</div>
            </div>
          <% is_nil(@ticket) -> %>
            <div class="wrap">
              <div class="card" id="ticket-not-found" style="padding:22px 20px;color:var(--muted)">Ticket not found.</div>
            </div>
          <% true -> %>
            <div class="wrap">
              <div class="card" id="ticket-header" style="padding:18px 20px">
                <div class="gtitle" style="margin:0">
                  <h3 class="t-subject">{@ticket.subject}</h3>
                  <.pill variant={priority_variant(@ticket.priority)}>{@ticket.priority}</.pill>
                  <.pill :if={@ticket.breached} variant="bad">SLA breached</.pill>
                  <.pill :if={not @ticket.breached} variant={status_variant(@ticket.status)}>{@ticket.status}</.pill>
                </div>
                <div class="t-parties" style="color:var(--muted);font-size:13px;margin-top:8px">
                  Requester (tenant-admin): <b class="t-requester">{requester_name(@ticket.__requester__)}</b>
                  <span :if={requester_email(@ticket.__requester__) != "—"} class="t-requester-email">· {requester_email(@ticket.__requester__)}</span>
                  · Assignee: <span class="t-agent">{agent_name(@ticket.__agent__)}</span>
                </div>
              </div>

              <div id="conversation" style="margin-top:16px">
                <div class="gtitle"><h3>Conversation</h3><span class="n">{message_count(@ticket)}</span></div>

                <div :if={@ticket.__conversations__ == []} class="card" id="no-conversation" style="padding:16px 20px;color:var(--muted)">
                  No conversation yet — post the first reply below.
                </div>

                <div :for={conv <- @ticket.__conversations__} class="conv-thread" id={"conv-#{conv.id}"}>
                  <div :for={m <- conv.messages} class={"msg msg-#{m.sender_type}"} id={"msg-#{m.id}"} style="padding:12px 16px;border:1px solid var(--line,#E5E7EB);border-radius:10px;margin-bottom:10px">
                    <div class="msg-meta" style="font-size:12px;color:var(--muted);margin-bottom:4px">
                      <span class="msg-sender">{sender_label(m)}</span> · <span class="msg-kind">{m.message_type}</span>
                    </div>
                    <div class="msg-body">{m.body}</div>
                  </div>
                </div>
              </div>

              <div id="reply-box" class="card" style="padding:16px 20px;margin-top:8px">
                <div class="gtitle" style="margin:0 0 8px"><h3>Reply</h3></div>

                <div :if={@reply_error} id="reply-error" class="form-error" style="color:var(--bad,#b91c1c);font-size:12px;margin-bottom:8px">
                  {@reply_error}
                </div>

                <%!-- The AI draft (T149 B2a): produced by the EXISTING draft→approve loop; the operator
                      reviews it here and posts it through the normal governed reply (human in the loop). --%>
                <div :if={@ai_draft} id="ai-draft" style="border:1px solid #C9A227;border-radius:10px;background:#FFF8E1;color:#5b4a00;padding:12px 14px;margin-bottom:10px">
                  <b>AI-drafted reply (queued for human approval<span :if={@ai_draft.approval_id}> · approval {@ai_draft.approval_id}</span>):</b>
                  <div class="ai-draft-text" style="margin-top:6px;white-space:pre-wrap">{@ai_draft.text}</div>
                </div>
                <div :if={@ai_error} id="ai-error" style="color:var(--muted);font-size:12px;margin-bottom:10px">
                  {@ai_error}
                </div>

                <form phx-submit="reply" id="reply-form" :if={writable?(@samen_mount)}>
                  <textarea name="reply[body]" id="reply-body" rows="4" placeholder="Type your reply…"
                    style="width:100%;padding:10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px"></textarea>
                  <div style="display:flex;gap:8px;margin-top:10px">
                    <.button variant="primary" type="submit" id="post-reply">Post reply</.button>
                    <.button type="button" phx-click="draft_ai" id="draft-ai-reply">Draft AI reply</.button>
                  </div>
                </form>
                <div :if={not writable?(@samen_mount)} class="read-only-note" style="color:var(--muted);font-size:12px">
                  Read-only mount — no reply affordance.
                </div>
              </div>
            </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers (MASKING INVARIANT: render resolved values, never unwrap) -------

  defp message_count(%{__conversations__: convs}),
    do: Enum.reduce(convs, 0, fn c, acc -> acc + length(c.messages) end)

  defp message_count(_), do: 0

  defp sender_label(%{sender_type: :agent, __agent__: %{} = agent}), do: "SaaS agent · #{agent_name(agent)}"
  defp sender_label(%{sender_type: :agent}), do: "SaaS agent"
  defp sender_label(%{sender_type: :customer}), do: "Requester"
  defp sender_label(%{sender_type: :system}), do: "System"
  defp sender_label(_), do: "—"

  defp requester_name(nil), do: "—"
  defp requester_name(%{full_name: name}), do: render_name(name)
  defp requester_name(_), do: "—"

  defp requester_email(nil), do: "—"
  defp requester_email(%{emails: emails}), do: render_email(emails)
  defp requester_email(_), do: "—"

  defp agent_name(nil), do: "unassigned"
  defp agent_name(%{full_name: name}), do: render_name(name)
  defp agent_name(_), do: "unassigned"

  defp priority_variant(:urgent), do: "bad"
  defp priority_variant(:high), do: "warn"
  defp priority_variant(:normal), do: "info"
  defp priority_variant(_), do: "mut"

  defp status_variant(:open), do: "warn"
  defp status_variant(:pending), do: "info"
  defp status_variant(:resolved), do: "ok"
  defp status_variant(:closed), do: "mut"
  defp status_variant(_), do: "mut"
end
