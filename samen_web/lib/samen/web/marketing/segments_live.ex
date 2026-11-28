defmodule Samen.Web.Marketing.SegmentsLive do
  @moduledoc """
  Framework Marketing / Segments (`/marketing/segments`) — the prospecting audience view
  (ADR-011 §8). Lists the host's `<ns>.Segment` rows (name / description / subscriber_count /
  filter criteria summary) + the org's subscribers (email 🔒 PII-resolved: tenant clear /
  operator ••••) with the per-row suppression flag, so an operator SEES which subscribers
  are opted-out. Non-PII except the subscriber email column, which flows through
  PiiResolution.

  ## A3 retrofit — ListLive + CRUD (marketing batch)

  The SEGMENTS list rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.segments_page/3` buys sort/filter/keyset-pagination/empty-state as kit
  defaults. The write side (AC-G1-1/2): "New segment" opens a `modal/1` hosting an
  `AshPhoenix.Form`-backed `simple_form/1` create (`name` required); each row carries a
  `delete_confirm/1`. Write affordances are tenant-plane only
  (`:can_admin`, an admin on the tenant plane); enforcement stays in the kernel (OrgScope +
  admin role gate).

  ## The subscribers audience panel (BOUNDED companion list)

  The kit's list-event contract is ONE `ListLive`-managed list per LiveView (the
  `sort`/`filter`/`paginate` events carry no list id — a second `list_view` would
  mutate the segments list). The subscribers panel therefore renders the FIRST BOUNDED
  page of `Reads.subscribers_page/3` (keyset `limit` by construction — the old
  unbounded `Reads.subscribers/2` read is gone from this surface) in a `data_table`
  with the kit `empty_state` at zero rows and an explicit "first N of more" note when
  the audience exceeds the page. The per-row "suppressed" flag reads
  `Reads.suppressed_ids/3` — bounded to exactly the page's subscriber ids.

  ## MASKING INVARIANT

  `Subscriber.email` renders whatever `PiiResolution` resolved: tenant clear, operator
  `%Masked{}` → `••••`. This LiveView never unwraps a `%Masked{}`, never calls the
  vault, and has no "show plaintext" branch. This page offers NO subscriber write —
  subscribers enter through consented paths (`Reads.add_subscriber/3`, ADR-011 §7.3).
  """
  use Phoenix.LiveView

  import Samen.UI

  import Samen.Web.Marketing.Live,
    only: [
      assign_mount: 2,
      marketing_sidebar: 1,
      marketing_path: 1,
      marketing_plane_note: 1
    ]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Reads.Guard
  alias Samen.Web.Mount
  alias Samen.Web.TenantActor
  require TenantActor
  import Samen.Web.TenantActor.Components, only: [actor_refused: 1]

  alias Samen.Web.Marketing.Reads

  use Samen.Web.ListLive,
    resource: Segment,
    reads: &Samen.Web.Marketing.Reads.segments_page/3,
    sortable: [:name, :subscriber_count],
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
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> Samen.Web.ListLive.refuse()
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil)
    |> assign(acting_scope: nil, actor_state: :ok, can_write: false, can_admin: false)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(sub_page: %Samen.Web.Page{}, suppressed_ids: MapSet.new(), subscribers_failed: false, suppressions_failed: false)
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  # ADR-045 §4.4 - WHO acts: the signed-in person's resolved membership role (`Samen.Web.TenantActor`), never
  # `Mount.scope/2`'s fixed `:member`. A denial or a failed lookup is a STATE of the page: nothing is read, nothing
  # can be written, and the page is re-resolved on every `handle_params`.
  def load(socket, org_id) do
    case TenantActor.assign_actor(socket, org_id) do
      {:ok, socket} -> load_for(socket, org_id, socket.assigns.acting_scope)
      {:refused, socket} -> load_refused(socket, org_id)
    end
  end

  # Acting again with no URL to patch to (`Samen.Web.TenantActor`, the "Check again" button): the same load a navigation does.
  @doc false
  def actor_regained(%{assigns: %{org_id: _}} = socket), do: load(socket, socket.assigns.org_id)

  # The refused state an OPEN page falls into when the guard stops an event (`Samen.Web.TenantActor.recheck_event/3`): the
  # same load a refused navigation does, so no segment and no subscriber the page loaded is kept.
  @doc false
  def actor_lost(%{assigns: %{org_id: _}} = socket), do: load_refused(socket, socket.assigns.org_id)

  # The person's role or id changed while the page was open: a form built at load holds the scope it was built with, so it
  # is built again with the fresh one.
  @doc false
  def actor_changed(%{assigns: %{samen_mount: mount, org_id: org_id, acting_scope: acting}} = socket),
    do: assign(socket, new_form: new_segment_form(mount, org_id, acting))

  defp load_refused(socket, org_id) do
    socket
    |> Samen.Web.ListLive.refuse()
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(sub_page: %Samen.Web.Page{}, suppressed_ids: MapSet.new(), subscribers_failed: false, suppressions_failed: false)
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  defp load_for(socket, org_id, scope) do
    mount = socket.assigns.samen_mount

    # The BOUNDED subscribers panel: first keyset page (default page size), PII
    # plane-resolved; the suppression flag read is bounded to the page's own ids.
    sub_page = Reads.subscribers_page(mount, scope, %Samen.Web.ListState{})
    suppressed = Reads.suppressed_ids_result(mount, scope, Enum.map(sub_page.items, & &1.id))
    suppressed_ids = Samen.Web.Reads.Guard.value(suppressed, MapSet.new())

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id)
    |> assign(
      sub_page: sub_page,
      suppressed_ids: suppressed_ids,
      subscribers_failed: Samen.Web.Reads.Guard.unavailable?(sub_page),
      suppressions_failed: Samen.Web.Reads.Guard.unavailable?(suppressed)
    )
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_segment_form(mount, org_id, scope))
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  # The kit error state's "Try again" (a failed subscribers / suppression read).
  @impl true
  TenantActor.refuse_events()

  def handle_event("retry_load", _params, socket), do: {:noreply, load(socket, socket.assigns.org_id)}

  def handle_event("new_segment", _params, socket) do
    %{samen_mount: mount, org_id: org_id, acting_scope: acting} = socket.assigns
    {:noreply, assign(socket, show_new: true, new_form: new_segment_form(mount, org_id, acting))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # `org_id` is the server-side fact, never client input. Segment is non-PII; the
  # kernel's OrgScope + admin-role policies gate the write — this view adds no policy.
  def handle_event("save_new", %{"form" => params}, socket) do
    case Guard.submit_form(:marketing_save_segment, socket.assigns[:org_id], socket.assigns.new_form, with_org(params, socket)) do
      {:ok, _segment} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, kind} when is_atom(kind) ->
        {:noreply, put_flash(socket, :error, Guard.write_copy(kind, "save that segment"))}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # FAIL-HONEST delete: refusals (e.g. an FK-linked segment) surface on the page.
  # Admin-gated by the kernel → it runs with the acting person's own scope.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id, acting_scope: acting} = socket.assigns

    case Reads.delete_segment(mount, TenantActor.write_scope(mount, org_id, acting), id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           delete_error: "Could not delete this segment — it still has linked records."
         )}
    end
  end

  # Segment writes are ADMIN-gated by the kernel (`RoleAtLeast :admin`); the form
  # scope is the acting person's own (`TenantActor.write_scope/3`).
  defp new_segment_form(mount, org_id, acting) do
    Mount.resource(mount, Segment)
    |> AshPhoenix.Form.for_create(:create, scope: TenantActor.write_scope(mount, org_id, acting))
    |> to_form()
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

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
            <.button :if={@can_admin and not @no_org} variant="primary" phx-click="new_segment" id="new-segment">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New segment
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= cond do %>
        <% @no_org -> %>
          <.no_org_card mount={@samen_mount} />
        <% @actor_state in [:denied, :unavailable] -> %>
          <.actor_refused state={@actor_state} title="Segments" nothing="there are no segments to show" />
        <% true -> %>
          <span id="org-banner" style="display:none">Marketing org: {@org_id}</span>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="wrap">
            <div id="segments">
              <div class="gtitle">
                <h3>Audience segments</h3>
                <span class="n">{length(@page.items)}</span>
              </div>
              <.list_view
                id="segments-list"
                page={@page}
                state={@list_state}
                row_class="segment-row"
                filter_placeholder="Filter segments…"
                empty_text="No segments yet."
                empty_icon="◔"
                empty_body="Segments are the audiences your campaigns send to."
              >
                <:empty_actions :if={@can_admin}>
                  <.button variant="primary" phx-click="new_segment" id="empty-new-segment">New segment</.button>
                </:empty_actions>
                <:head>
                  <.sort_header field={:name} label="Segment" sort={@list_state.sort} width="30%" />
                  <.sort_header field={:subscriber_count} label="Subscribers" sort={@list_state.sort} width="18%" />
                  <th scope="col" style="width:42%">Filter</th>
                  <th :if={@can_admin} scope="col" style="width:10%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={s}>
                  <td style="font-weight:500">{s.name}
                    <div :if={s.description} style="font-size:12px;color:var(--muted)">{s.description}</div>
                  </td>
                  <td style="color:var(--muted)">{s.subscriber_count}</td>
                  <td style="font-size:12px;color:var(--muted)">{filter_summary(s.filter_criteria)}</td>
                  <td :if={@can_admin} class="segment-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={s.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <div class="wrap">
            <div id="subscribers">
              <div class="gtitle">
                <h3>Subscribers</h3>
                <span class="n">{length(@sub_page.items)}</span>
                <span class="lane">· email via PiiResolution · {marketing_plane_note(@samen_mount)}</span>
              </div>
              <%= if @subscribers_failed do %>
                <.error_state class="subscribers-error" body={Samen.Web.Reads.Guard.message()} retry_event="retry_load" />
              <% else %>
              <.error_state :if={@suppressions_failed} class="suppressions-error" title="Suppression flags unavailable" body={Samen.Web.Reads.Guard.message()} retry_event="retry_load" />
              <%= if @sub_page.items == [] do %>
                <.empty_state
                  class="subscribers-empty"
                  icon="◔"
                  title="No subscribers yet."
                  body="Subscribers you add to this segment appear here with status and source."
                />
              <% else %>
                <.data_table>
                  <:head>
                    <th scope="col" style="width:44%">Email</th>
                    <th scope="col" style="width:20%">Status</th>
                    <th scope="col" style="width:20%">Consent</th>
                    <th scope="col" style="width:16%">Suppressed</th>
                  </:head>
                  <tr :for={s <- @sub_page.items} class="subscriber-row" id={"subscriber-#{s.id}"}>
                    <td class="subscriber-email" style="font-size:12px;color:var(--muted)">{s.email}</td>
                    <td><.pill variant={sub_status_variant(s.status)}>{s.status}</.pill></td>
                    <td style="font-size:12px;color:var(--muted)">{if s.consent_at, do: "opted-in", else: "—"}</td>
                    <td>
                      <span :if={MapSet.member?(@suppressed_ids, s.id)} class="suppressed-flag"><.pill variant="bad">suppressed</.pill></span>
                      <span :if={!MapSet.member?(@suppressed_ids, s.id) and not @suppressions_failed} style="color:var(--muted);font-size:12px">—</span>
                      <span :if={@suppressions_failed} class="suppressed-unknown" style="color:var(--muted);font-size:12px">unknown</span>
                    </td>
                  </tr>
                </.data_table>
                <div :if={@sub_page.has_more} class="subscribers-bounded-note" style="color:var(--muted);font-size:12px;margin-top:8px">
                  Showing the first {@sub_page.page_size} subscribers — the audience is larger.
                </div>
              <% end %>
              <% end %>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and @can_admin} id="new-segment-modal" title="New segment" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-segment-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:name]} label="Name" />
              <.form_field field={f[:description]} label="Description" type="textarea" />
              <:actions>
                <.button variant="primary" type="submit">Save segment</.button>
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
