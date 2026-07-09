defmodule Samen.Web.Marketing.SegmentsLive do
  @moduledoc """
  Framework Marketing / Segments (`/marketing/segments`) — the prospecting audience view
  (ADR-011 §8). Lists the host's `<ns>.Segment` rows (name / description / subscriber_count /
  filter criteria summary) + the org's subscribers (email 🔒 PII-resolved: tenant clear /
  operator ••••) + the active suppression list, so an operator SEES which subscribers are
  opted-out. Non-PII except the subscriber email column, which flows through PiiResolution.
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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, segments: [], subscribers: [], suppressed_ids: MapSet.new())
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    suppressed_ids =
      Reads.suppressions(mount, scope)
      |> Enum.map(& &1.subscriber_id)
      |> MapSet.new()

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      segments: Reads.segments(mount, scope),
      subscribers: Reads.subscribers(mount, scope),
      suppressed_ids: suppressed_ids
    )
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mkt-segments">
      <.app_shell>
        <:sidebar>
          <.marketing_sidebar mount={@samen_mount} org_id={@org_id} active={:marketing_segments} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Segments" crumbs={crumbs(@samen_mount, @org_id, "Segments")}>
          <:actions>
            <a href={leads_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">Leads</a>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Marketing org: {@org_id}</span>

          <div class="wrap">
            <div id="segments">
              <div class="gtitle">
                <h3>Audience segments</h3>
                <span class="n">{length(@segments)}</span>
              </div>
              <%= if @segments == [] do %>
                <div class="card" style="padding:22px 20px;color:var(--muted)">No segments yet.</div>
              <% else %>
                <.data_table>
                  <:head>
                    <th style="width:34%">Segment</th>
                    <th style="width:20%">Subscribers</th>
                    <th style="width:46%">Filter</th>
                  </:head>
                  <tr :for={s <- @segments} class="segment-row" id={"segment-#{s.id}"}>
                    <td style="font-weight:500">{s.name}
                      <div :if={s.description} style="font-size:12px;color:var(--muted)">{s.description}</div>
                    </td>
                    <td style="color:var(--muted)">{s.subscriber_count}</td>
                    <td style="font-size:12px;color:var(--muted)">{filter_summary(s.filter_criteria)}</td>
                  </tr>
                </.data_table>
              <% end %>
            </div>
          </div>

          <div class="wrap">
            <div id="subscribers">
              <div class="gtitle">
                <h3>Subscribers</h3>
                <span class="n">{length(@subscribers)}</span>
                <span class="lane">· email via PiiResolution · {marketing_plane_note(@samen_mount)}</span>
              </div>
              <%= if @subscribers == [] do %>
                <div class="card" style="padding:22px 20px;color:var(--muted)">No subscribers yet.</div>
              <% else %>
                <.data_table>
                  <:head>
                    <th style="width:44%">Email</th>
                    <th style="width:20%">Status</th>
                    <th style="width:20%">Consent</th>
                    <th style="width:16%">Suppressed</th>
                  </:head>
                  <tr :for={s <- @subscribers} class="subscriber-row" id={"subscriber-#{s.id}"}>
                    <td class="subscriber-email" style="font-size:12px;color:var(--muted)">{s.email}</td>
                    <td><.pill variant={sub_status_variant(s.status)}>{s.status}</.pill></td>
                    <td style="font-size:12px;color:var(--muted)">{if s.consent_at, do: "opted-in", else: "—"}</td>
                    <td>
                      <span :if={MapSet.member?(@suppressed_ids, s.id)} class="suppressed-flag"><.pill variant="bad">suppressed</.pill></span>
                      <span :if={!MapSet.member?(@suppressed_ids, s.id)} style="color:var(--muted);font-size:12px">—</span>
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

  defp leads_path(mount, org_id), do: "#{marketing_path(mount)}/leads?org=#{org_id}"

  defp filter_summary(criteria) when is_map(criteria) and map_size(criteria) > 0 do
    criteria
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Enum.join(", ")
  end

  defp filter_summary(_), do: "all active subscribers"

  defp sub_status_variant(:active), do: "ok"
  defp sub_status_variant(:unsubscribed), do: "bad"
  defp sub_status_variant(:bounced), do: "warn"
  defp sub_status_variant(:complained), do: "bad"
  defp sub_status_variant(_), do: "mut"
end
