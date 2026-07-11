defmodule Samen.Web.Marketing.CampaignsLive do
  @moduledoc """
  Framework Marketing / Campaigns list (`/marketing/campaigns`) — ADR-011 §7.2.

  A campaigns/sequences list over the host's `<ns>.Campaign`. Non-PII (campaign rows
  carry only name/status/schedule). Each row links to `CampaignLive` (compose + send).

  ## A3 retrofit — ListLive + CRUD (marketing batch)

  The list rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.campaigns_page/3` buys sort/filter/keyset-pagination/empty-state as kit
  defaults (no unbounded `read!`, no list `handle_event/3` of its own). The
  per-campaign send count is an `Ash.count` DB aggregate attached by the reads fn, so
  it stays fresh across pagination. The write side (AC-G1-1/2): "New campaign" opens a
  `modal/1` hosting an `AshPhoenix.Form`-backed `simple_form/1` create (`name` is
  required — the inline-error path is real); each row carries a `delete_confirm/1`.
  Write affordances are offered on the tenant plane only
  (`Samen.Web.Marketing.Live.writable?/1`); enforcement stays in the kernel (OrgScope +
  admin role gate on every Campaign write). Send composition stays on `CampaignLive` —
  the ONLY send path remains `Reads.enqueue_send/3` (consent + suppression enforced).
  """
  use Phoenix.LiveView

  import Samen.UI

  import Samen.Web.Marketing.Live,
    only: [
      assign_mount: 2,
      marketing_sidebar: 1,
      marketing_path: 1,
      marketing_plane_note: 1,
      writable?: 1
    ]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Marketing.Reads

  use Samen.Web.ListLive,
    resource: Campaign,
    reads: &Samen.Web.Marketing.Reads.campaigns_page/3,
    sortable: [:name, :status, :scheduled_at],
    filter_fields: [:name, :description],
    default_sort: {:name, :asc}

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id)
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_campaign_form(mount, org_id))
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_campaign", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    {:noreply, assign(socket, show_new: true, new_form: new_campaign_form(mount, org_id))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # `org_id` is the server-side fact, never client input. Campaign is non-PII; the
  # kernel's OrgScope + admin-role policies gate the write — this view adds no policy.
  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _campaign} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # FAIL-HONEST delete: the kernel defines no cascade — a campaign with linked
  # sends is refused by the DB (FK) and the refusal is SURFACED on the page.
  # Admin-gated by the kernel → the plane-preserving `write_scope/2`.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Reads.delete_campaign(mount, Reads.write_scope(mount, org_id), id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           delete_error: "Could not delete this campaign — it still has linked records (sends)."
         )}
    end
  end

  # Campaign writes are ADMIN-gated by the kernel (`RoleAtLeast :admin`); the form
  # scope is the plane-preserving same-org elevation (`Reads.write_scope/2`).
  defp new_campaign_form(mount, org_id) do
    Mount.resource(mount, Campaign)
    |> AshPhoenix.Form.for_create(:create, scope: Reads.write_scope(mount, org_id))
    |> to_form()
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

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
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_campaign" id="new-campaign">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New campaign
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Marketing org: {@org_id}</span>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="wrap">
            <div id="campaigns">
              <div class="gtitle">
                <h3>Campaigns &amp; sequences</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· consent + suppression enforced on every send · {marketing_plane_note(@samen_mount)}</span>
              </div>

              <.list_view
                id="campaigns-list"
                page={@page}
                state={@list_state}
                row_class="campaign-row"
                filter_placeholder="Filter campaigns…"
                empty_text="No campaigns yet."
                empty_icon="✉"
                empty_body="Campaigns send to a segment through the fail-honest delivery engine."
              >
                <:empty_actions :if={writable?(@samen_mount)}>
                  <.button variant="primary" phx-click="new_campaign" id="empty-new-campaign">New campaign</.button>
                </:empty_actions>
                <:head>
                  <.sort_header field={:name} label="Campaign" sort={@list_state.sort} width="30%" />
                  <.sort_header field={:status} label="Status" sort={@list_state.sort} width="14%" />
                  <.sort_header field={:scheduled_at} label="Scheduled" sort={@list_state.sort} width="20%" />
                  <th scope="col" style="width:12%">Sends</th>
                  <th scope="col" style="width:14%"></th>
                  <th :if={writable?(@samen_mount)} scope="col" style="width:10%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={c}>
                  <td style="font-weight:500">
                    <a href={campaign_path(@samen_mount, @org_id, c.id)} style="color:#3B4CCA;text-decoration:none">{c.name}</a>
                    <div :if={c.description} style="font-size:12px;color:var(--muted)">{c.description}</div>
                  </td>
                  <td><.pill variant={status_variant(c.status)}>{c.status}</.pill></td>
                  <td style="color:var(--muted);font-size:12px">{fmt_dt(c.scheduled_at)}</td>
                  <td class="campaign-sends" style="color:var(--muted)">{Map.get(c, :send_count, 0)}</td>
                  <td>
                    <a href={campaign_path(@samen_mount, @org_id, c.id)} class="btn" style="text-decoration:none;font-size:12px">Compose</a>
                  </td>
                  <td :if={writable?(@samen_mount)} class="campaign-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={c.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-campaign-modal" title="New campaign" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-campaign-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:name]} label="Name" />
              <.form_field field={f[:description]} label="Description" type="textarea" />
              <:actions>
                <.button variant="primary" type="submit">Save campaign</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
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
