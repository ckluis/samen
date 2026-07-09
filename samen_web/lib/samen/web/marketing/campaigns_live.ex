defmodule Samen.Web.Marketing.CampaignsLive do
  @moduledoc """
  Framework Marketing / Campaigns list (`/marketing/campaigns`) — ADR-011 §7.2.

  A campaigns/sequences list over the host's `<ns>.Campaign`, read via
  `Samen.Web.Marketing.Reads.campaigns/2`. Non-PII (campaign rows carry only name/status/
  schedule). Each row links to `CampaignLive` (compose + send). A per-campaign send count is
  read from the host's `Send` rows.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Marketing.Live, only: [assign_mount: 2, marketing_sidebar: 1, marketing_path: 1, marketing_plane_note: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Marketing.Reads

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, campaigns: [], send_counts: %{})
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    campaigns = Reads.campaigns(mount, scope)

    send_counts =
      Map.new(campaigns, fn c ->
        {c.id, length(Reads.sends_for_campaign(mount, scope, c.id))}
      end)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, campaigns: campaigns, send_counts: send_counts)
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mkt-campaigns">
      <.app_shell>
        <:sidebar>
          <.marketing_sidebar mount={@samen_mount} org_id={@org_id} active={:marketing_campaigns} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Campaigns" crumbs={crumbs(@samen_mount, @org_id, "Campaigns")}>
          <:actions>
            <a href={segments_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">Segments</a>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Marketing org: {@org_id}</span>

          <div class="wrap">
            <div id="campaigns">
              <div class="gtitle">
                <h3>Campaigns &amp; sequences</h3>
                <span class="n">{length(@campaigns)}</span>
                <span class="lane">· consent + suppression enforced on every send · {marketing_plane_note(@samen_mount)}</span>
              </div>

              <%= if @campaigns == [] do %>
                <div class="card" style="padding:22px 20px;color:var(--muted)">
                  No campaigns yet. Seed a campaign, or create one from the Marketing scope.
                </div>
              <% else %>
                <.data_table>
                  <:head>
                    <th style="width:34%">Campaign</th>
                    <th style="width:16%">Status</th>
                    <th style="width:22%">Scheduled</th>
                    <th style="width:14%">Sends</th>
                    <th style="width:14%"></th>
                  </:head>
                  <tr :for={c <- @campaigns} class="campaign-row" id={"campaign-#{c.id}"}>
                    <td style="font-weight:500">
                      <a href={campaign_path(@samen_mount, @org_id, c.id)} style="color:#3B4CCA;text-decoration:none">{c.name}</a>
                      <div :if={c.description} style="font-size:12px;color:var(--muted)">{c.description}</div>
                    </td>
                    <td><.pill variant={status_variant(c.status)}>{c.status}</.pill></td>
                    <td style="color:var(--muted);font-size:12px">{fmt_dt(c.scheduled_at)}</td>
                    <td style="color:var(--muted)">{Map.get(@send_counts, c.id, 0)}</td>
                    <td>
                      <a href={campaign_path(@samen_mount, @org_id, c.id)} class="btn" style="text-decoration:none;font-size:12px">Compose</a>
                    </td>
                  </tr>
                </.data_table>
              <% end %>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Marketing", leaf]

  defp campaign_path(mount, org_id, id),
    do: "#{marketing_path(mount)}/campaigns/#{id}?org=#{org_id}"

  defp segments_path(mount, org_id), do: "#{marketing_path(mount)}/segments?org=#{org_id}"

  defp status_variant(:draft), do: "mut"
  defp status_variant(:scheduled), do: "info"
  defp status_variant(:sending), do: "warn"
  defp status_variant(:sent), do: "ok"
  defp status_variant(:cancelled), do: "bad"
  defp status_variant(_), do: "mut"

  defp fmt_dt(%DateTime{} = dt),
    do: "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)} #{pad(dt.hour)}:#{pad(dt.minute)} UTC"

  defp fmt_dt(_), do: "—"

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")
end
