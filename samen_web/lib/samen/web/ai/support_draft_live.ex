defmodule Samen.Web.AI.SupportDraftLive do
  @moduledoc """
  Surface 5/5 — the D5 support-reply DRAFT composer. `Samen.AI.SupportOperator.draft_reply/3`
  grounds (masked), persists a `Samen.AI.SupportReplyDraft` row, and opens a PENDING
  `ai_support_reply` approval decided by a DISTINCT human — it NEVER sends. The kit is
  host-agnostic: draft PERSISTENCE requires the host to have adopted `Samen.AI.Domain` (repo
  + migration + approval registration; proven end-to-end in driftwood, T155). Until a host
  adopts it, `draft_reply/3` fail-honests and this surface reports it truthfully — never a
  fabricated "draft saved".

  `org_id` is injected into the draft attrs from the TRUSTED scope by the server, never from
  client params; the draft LIST is org-scoped (patch 142).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Live, only: [assign_mount: 2]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, name: 2]
  import Samen.Web.AI.Components

  alias Samen.Web.AI.Server
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = Samen.Web.CurrentOrg.resolve(mount, params, session)
    {:ok, load(socket, org_id)}
  end

  @doc "The framework page-load seam."
  def load(socket, org_id, opts \\ []) do
    mount = socket.assigns[:samen_mount]
    drafts = if org_id, do: Server.list_drafts(mount, org_id), else: []

    socket
    |> Phoenix.Component.assign(:org_id, org_id)
    |> Phoenix.Component.assign(:to_subscriber_id, Keyword.get(opts, :to_subscriber_id, ""))
    |> Phoenix.Component.assign(:inbound_ref, Keyword.get(opts, :inbound_ref, ""))
    |> Phoenix.Component.assign(:instruction, Keyword.get(opts, :instruction, ""))
    |> Phoenix.Component.assign(:drafts, drafts)
    |> Phoenix.Component.assign(:outcome, Keyword.get(opts, :outcome, nil))
  end

  @impl true
  def handle_event("compose", params, socket) do
    org_id = socket.assigns.org_id

    outcome =
      if org_id do
        attrs =
          %{
            to_subscriber_id: present(params["to_subscriber_id"]),
            inbound_ref: present(params["inbound_ref"]),
            body: present(params["instruction"]) || "Draft a reply."
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        classify_outcome(Server.support_draft(socket.assigns.samen_mount, org_id, attrs))
      else
        nil
      end

    {:noreply,
     load(socket, org_id,
       to_subscriber_id: params["to_subscriber_id"] || "",
       inbound_ref: params["inbound_ref"] || "",
       instruction: params["instruction"] || "",
       outcome: outcome
     )}
  end

  # A draft compose returns {:ok, %{draft, approval}} on a host that adopted the domain;
  # otherwise a fail-honest error term — surfaced truthfully (never "saved" on failure).
  defp classify_outcome({:ok, _}), do: {:saved, "Draft persisted; a pending approval was opened (no send)."}
  defp classify_outcome({:error, :not_configured}), do: {:not_configured, Server.configuration_hint()}
  defp classify_outcome({:error, {:persist_unavailable, _}}), do: {:unavailable, "This host has not adopted the AI draft domain — nothing was persisted."}
  defp classify_outcome({:error, _}), do: {:unavailable, "Draft could not be persisted — nothing was saved."}

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar title={name(@samen_mount, @org_id)} subtitle="AI" logo={Mount.label(@samen_mount, :glyph, "AI")}>
          <.ai_sidebar_nav active={:support} base={ai_base(@samen_mount)} />
        </.sidebar>
      </:sidebar>

      <.topbar title="AI · Support draft" crumbs={["AI", "Support draft"]} />
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
      <.ai_tabs active={:support} base={ai_base(@samen_mount)} />

      <%= if is_nil(@org_id) do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="pane" style="display:flex;flex-direction:column;gap:16px;padding:16px">
          <form phx-submit="compose" class="card" style="display:flex;flex-direction:column;gap:10px;padding:16px">
            <label style="font-size:13px;font-weight:600">Recipient subscriber id (token)</label>
            <input type="text" name="to_subscriber_id" id="ai-support-subscriber" value={@to_subscriber_id} placeholder="subscriber UUID" />

            <label style="font-size:13px;font-weight:600">Inbound ref (object-ref, optional)</label>
            <input type="text" name="inbound_ref" id="ai-support-inbound" value={@inbound_ref} />

            <label style="font-size:13px;font-weight:600">Draft instruction</label>
            <textarea name="instruction" id="ai-support-instruction" rows="3">{@instruction}</textarea>

            <div><.button variant="primary" type="submit">Compose draft (never sends)</.button></div>
          </form>

          <.compose_outcome :if={@outcome} outcome={@outcome} />

          <div class="card" id="ai-support-drafts" style="padding:16px">
            <h3 style="margin:0 0 8px;font-size:14px">Drafts in this org</h3>
            <%= if @drafts == [] do %>
              <.empty_state title="No drafts yet" body="Compose one above. Drafts are human-approved before any send." icon="✎" />
            <% else %>
              <ul style="list-style:none;margin:0;padding:0">
                <li :for={d <- @drafts} class="ai-draft-row" id={"ai-draft-#{d.id}"} data-simulated={to_string(draft_simulated?(d))} style="padding:8px 0;border-bottom:1px solid var(--line,#222)">
                  <.pill variant={status_variant(d.status)}>{d.status}</.pill>
                  <%!-- PP-16: a stored keyless/deterministic (SIMULATED) draft carries the loud
                        honesty badge from the persisted `:simulated` provenance — never laundered
                        as a genuine model reply. --%>
                  <.pill :if={draft_simulated?(d)} variant="warn"><span class="ai-draft-badge">SIMULATED — not a real model</span></.pill>
                  <span style="margin-left:8px">{draft_body(d)}</span>
                </li>
              </ul>
            <% end %>
          </div>
        </div>
      <% end %>
    </.app_shell>
    """
  end

  attr :outcome, :any, required: true

  defp compose_outcome(%{outcome: {:saved, msg}} = assigns) do
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <div class="card" id="ai-support-outcome" data-state="saved" style="padding:12px">
      <.pill variant="ok">Draft saved</.pill>
      <span style="margin-left:8px;color:var(--muted);font-size:13px">{@msg}</span>
    </div>
    """
  end

  defp compose_outcome(%{outcome: {:not_configured, hint}} = assigns) do
    assigns = assign(assigns, :hint, hint)

    ~H"""
    <div class="card" id="ai-support-outcome" data-state="not_configured" style="padding:12px">
      <.pill variant="bad">No AI provider wired</.pill>
      <pre id="ai-support-hint" style="white-space:pre-wrap;margin:8px 0 0;font-size:12px">{@hint}</pre>
    </div>
    """
  end

  defp compose_outcome(%{outcome: {:unavailable, msg}} = assigns) do
    assigns = assign(assigns, :msg, msg)

    ~H"""
    <div class="card" id="ai-support-outcome" data-state="unavailable" style="padding:12px">
      <.pill variant="warn">Not persisted</.pill>
      <span style="margin-left:8px;color:var(--muted);font-size:13px">{@msg}</span>
    </div>
    """
  end

  defp status_variant(:draft), do: "info"
  defp status_variant(:sent), do: "ok"
  defp status_variant(:discarded), do: "mut"
  defp status_variant(_), do: "mut"

  defp draft_body(%{body: body}) when is_binary(body), do: String.slice(body, 0, 120)
  defp draft_body(_), do: "—"

  # PP-16: the persisted T152 honesty provenance — a stored draft whose body came from a
  # keyless/deterministic (SIMULATED) provider. A missing/false flag is a genuine draft (no
  # badge), so the badge is driven by the persisted flag, never assumed.
  defp draft_simulated?(%{simulated: true}), do: true
  defp draft_simulated?(_), do: false
end
