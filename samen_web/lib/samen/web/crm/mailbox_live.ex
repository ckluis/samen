defmodule Samen.Web.CRM.MailboxLive do
  @moduledoc """
  Framework CRM / **Mailbox settings** (`/crm/mailbox`) — the connect UI seam for the
  two-way email sync (spec §I1, T74).

  ## The honest empty state (the whole point of this surface)

  Three states, and the surface NEVER blurs them:

    1. **Not configured** — no mailbox provider is wired for this host
       (`Samen.Mailbox.provider_configured?/0` is `false`, which is what CI and every
       un-wired host see). The page says so, in those words, and offers NO connect
       affordance. It does NOT render an empty inbox, a "0 messages synced" tile, or
       a disabled-looking connect button that would imply a mailbox is one click
       away. "Unconfigured" and "connected but quiet" are different facts.
    2. **Configured, nothing connected** — a real provider is wired; no user has
       connected a mailbox yet. THIS is the state that gets the connect affordance.
    3. **Connected** — the connection rows, with the 🔒 mailbox address resolved
       through `Samen.Api.PiiResolution` (tenant clear / operator `••••`).

  A host that has not mounted `Samen.Scopes.Mailbox` at all also lands in state 1:
  `Samen.Web.CRM.Reads.mailbox_connections/2` returns `[]` because the resource does
  not exist — never a fabricated row.

  ## MASKING INVARIANT

  This LiveView NEVER calls `Samen.Vault.reveal/3`, NEVER unwraps a `%Samen.Masked{}`,
  and has NO "show plaintext" branch. The mailbox address renders exactly as the
  resolver returned it — `%Masked{}` renders `••••` via `Phoenix.HTML.Safe`.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CRM.Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      connections: [],
      provider_configured: Samen.Mailbox.provider_configured?(),
      scope_mounted: false,
      connect_notice: nil
    )
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      connections: Reads.mailbox_connections(mount, scope),
      # The fail-honest predicate — read from the adapter itself, never assumed.
      provider_configured: Samen.Mailbox.provider_configured?(),
      scope_mounted: not is_nil(Reads.mailbox_connection_resource(mount)),
      connect_notice: nil
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-mailbox">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_mailbox} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Mailbox" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "CRM", "Mailbox"]} />
        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="wrap">
            <%= cond do %>
              <% not @provider_configured -> %>
                <.empty_state
                  class="mailbox-not-configured"
                  icon="✉"
                  title="Mailbox sync is not configured."
                  body={not_configured_body(@scope_mounted)}
                />
                <div id="mailbox-honesty-note" style="padding:8px 20px;font-size:11px;color:var(--muted)">
                  No provider is wired, so nothing has been synced and nothing can be. This is not an empty
                  inbox — see docs/guides/mailbox-seam.md for the adapter callbacks a real connector implements.
                </div>
              <% @connections == [] -> %>
                <.empty_state
                  class="mailbox-none-connected"
                  icon="✉"
                  title="No mailbox connected yet."
                  body="Connect your mailbox to thread email onto the right contact and company timelines."
                />
                <div :if={writable?(@samen_mount)} id="mailbox-connect" style="padding:0 20px 16px">
                  <.button id="mailbox-connect-button" phx-click="connect">Connect mailbox</.button>
                  <div
                    :if={@connect_notice}
                    id="mailbox-connect-notice"
                    role="status"
                    style="margin-top:10px;font-size:12px;color:var(--muted);line-height:1.5"
                  >
                    {@connect_notice}
                  </div>
                </div>
              <% true -> %>
                <.data_table>
                  <:head>
                    <th style="width:40%">Mailbox</th>
                    <th style="width:20%">Provider</th>
                    <th style="width:20%">Status</th>
                    <th style="width:20%">Last synced</th>
                  </:head>
                  <tr :for={c <- @connections} class="mailbox-row" id={"mailbox-#{c.id}"}>
                    <td class="mailbox-address" style="font-weight:500;color:#3a3b45">{c.address}</td>
                    <td style="font-size:12px;color:var(--muted)">{c.provider}</td>
                    <td><.pill variant={status_variant(c.status)}>{c.status}</.pill></td>
                    <td style="font-size:12px;color:var(--muted)">{synced_at(c.last_synced_at)}</td>
                  </tr>
                </.data_table>
                <div style="padding:6px 20px 0;font-size:11px;color:var(--muted)">
                  · mailbox address via PiiResolution
                </div>
            <% end %>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # The connect affordance exists ONLY when a real provider is wired, so this handler
  # is unreachable in the unconfigured state. It still ANSWERS honestly rather than
  # silently doing nothing (T74 fix round, LOW-3): the OAuth/IMAP handshake needs
  # host-held credentials and a host-owned redirect, which this framework surface does
  # not and must not hold. It says exactly that instead of faking a spinner — the same
  # honesty the unconfigured empty state uses.
  @impl true
  def handle_event("connect", _params, socket) do
    {:noreply, assign(socket, connect_notice: connect_notice())}
  end

  defp connect_notice do
    "Connect needs the HOST to complete the provider handshake — this framework surface " <>
      "holds no mailbox credentials and mints no redirect. Call Samen.Mailbox.connect/2 " <>
      "from your host's OAuth callback (or IMAP credential form); the connected mailbox " <>
      "then appears here. See docs/guides/mailbox-seam.md."
  end

  defp not_configured_body(true),
    do:
      "The Mailbox scope is mounted, but no mailbox provider is wired for this host. " <>
        "Wire one with config :samen_core, :mailbox_provider, {MyAdapter.Provider, %{...}}."

  defp not_configured_body(false),
    do:
      "This host has not mounted the Mailbox scope and no mailbox provider is wired. " <>
        "Mount Samen.Scopes.Mailbox and wire a provider to enable two-way email sync."

  defp status_variant(:connected), do: "ok"
  defp status_variant(:error), do: "bad"
  defp status_variant(_), do: "mut"

  defp synced_at(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp synced_at(_), do: "never"
end
