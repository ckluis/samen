defmodule Samen.Web.CRM.CompaniesLive do
  @moduledoc """
  Framework CRM / Companies page — the inherited CRM domain rendered as real UI,
  host-agnostic (ADR-009). Companies are non-PII.

  ## A3 retrofit — ListLive + CRUD

  The list rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.companies_page/3` buys sort/filter/keyset-pagination/empty-state as kit
  defaults (no unbounded `read!`, no list `handle_event/3` of its own). The write side
  (AC-G1-1/2): "New company" opens a `modal/1` hosting an `AshPhoenix.Form`-backed
  `simple_form/1` create (`name` is required — the inline-error path is real); each row
  carries a `delete_confirm/1`. Write affordances are offered on the tenant plane only
  (`Samen.Web.CRM.Live.writable?/1`); enforcement stays in the kernel (OrgScope).

  ## Plane

  `mount.plane` produces the scope actor (`Samen.Web.Mount.scope/2`). On the tenant plane
  the org reads its own companies; on the operator plane the same page renders the same
  rows (Company has no PII to mask — the masking proof lives on the Contacts page).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Reads.Guard
  alias Samen.Web.Mount
  alias Samen.Web.TenantActor
  require TenantActor
  import Samen.Web.TenantActor.Components, only: [actor_refused: 1]

  alias Samen.Web.CRM.Reads

  use Samen.Web.ListLive,
    resource: Company,
    reads: &Samen.Web.CRM.Reads.companies_page/3,
    sortable: [:name, :industry, :size],
    filter_fields: [:name, :industry],
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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, metrics: nil, metric_errors: [])
    |> assign(acting_scope: nil, actor_state: :ok, can_write: false)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{}, list_error: nil)
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  # ADR-045 §4.4 — WHO acts: the signed-in person's resolved membership role
  # (`Samen.Web.TenantActor`), never `Mount.scope/2`'s fixed `:member`. A denial or a failed lookup is a
  # STATE of the page: nothing is read, nothing can be written.
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
  # same load a refused navigation does, so nothing the page loaded for the person it acted for is kept.
  @doc false
  def actor_lost(%{assigns: %{org_id: _}} = socket), do: load_refused(socket, socket.assigns.org_id)

  defp load_refused(socket, org_id) do
    socket
    |> Samen.Web.ListLive.refuse()
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id, metrics: nil, metric_errors: [])
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{}, list_error: nil)
    |> assign(show_new: false, new_form: nil)
    |> assign_new(:delete_error, fn -> nil end)
  end

  defp load_for(socket, org_id, scope) do
    mount = socket.assigns.samen_mount

    {metrics, metric_errors} = Reads.metrics_status(mount, scope)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      metrics: metrics,
      metric_errors: metric_errors
    )
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign(new_form: new_company_form(mount, scope))
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  TenantActor.refuse_events()

  def handle_event("new_company", _params, socket) do
    %{samen_mount: mount, acting_scope: scope} = socket.assigns
    {:noreply, assign(socket, show_new: true, new_form: new_company_form(mount, scope))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # `org_id` is the server-side fact, never client input. Company is non-PII; the
  # kernel's OrgScope policy still gates the write — this LiveView adds no policy.
  def handle_event("save_new", %{"form" => params}, socket) do
    case Guard.submit_form(:crm_save_company, socket.assigns[:org_id], socket.assigns.new_form, with_org(params, socket)) do
      {:ok, _company} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, kind} when is_atom(kind) ->
        {:noreply, put_flash(socket, :error, Guard.write_copy(kind, "save that company"))}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # ADR-040 §5.9/T37c: `Company` is `archivable true`, so `Reads.delete_company/3`'s
  # `Ash.destroy/2` now rides the default SOFT destroy (T36) — this sets
  # `archived_at` rather than removing the row, dropping it out of the default
  # (archived-excluding) bounded read below. No cascade is declared for CRM
  # (§5.4), so linked people/deals/attachments are untouched and the destroy is
  # never refused on their account; any `{:error, _}` here is a genuine failure
  # (e.g. an authorization denial), not the old FK-refusal case.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id, acting_scope: scope} = socket.assigns

    case Reads.delete_company(mount, scope, id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply, assign(socket, delete_error: "Could not delete this company.")}
    end
  end

  # The person's role or id changed while the page was open (`Samen.Web.TenantActor.recheck_event/3`): a form built at
  # load holds the scope it was built with, so it is built again with the fresh one.
  @doc false
  def actor_changed(%{assigns: %{samen_mount: mount, acting_scope: scope}} = socket),
    do: assign(socket, new_form: new_company_form(mount, scope))

  defp new_company_form(mount, scope) do
    Mount.resource(mount, Company)
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-companies">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_companies} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Companies" crumbs={crumbs(@samen_mount, @org_id, "Companies")}>
          <:actions>
            <.button :if={@can_write and not @no_org} variant="primary" phx-click="new_company" id="new-company">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New company
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= cond do %>
        <% @no_org -> %>
          <.no_org_card mount={@samen_mount} />
        <% @actor_state in [:denied, :unavailable] -> %>
          <.actor_refused state={@actor_state} title="Companies" nothing="there are no companies to show" />
        <% true -> %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <div class="metrics">
            <.metric label="Companies" value={@metrics && @metrics.companies || 0} error={:companies in @metric_errors}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Contacts" value={@metrics && @metrics.contacts || 0} error={:contacts in @metric_errors}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="8" r="3.2" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Open opportunities" value={@metrics && @metrics.open_opps || 0} error={:open_opps in @metric_errors}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.metric>
            <.metric
              label="Pipeline value"
              value={dollars((@metrics && @metrics.pipeline_value) || 0)}
              sub="open opportunities"
              error={:pipeline_value in @metric_errors}
            >
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="companies">
              <div class="gtitle">
                <h3>Companies</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· org-scoped · no PII</span>
              </div>
              <.list_view
                id="companies-list"
                page={@page}
                state={@list_state}
                error={@list_error}
                retry_event="list_retry"
                row_class="company-row"
                filter_placeholder="Filter companies…"
                empty_text="No companies yet."
                empty_icon="▣"
                empty_body="Companies group your contacts, deals, and activity in one place."
              >
                <:empty_actions :if={@can_write}>
                  <.button variant="primary" phx-click="new_company" id="empty-new-company">New company</.button>
                </:empty_actions>
                <:head>
                  <.sort_header field={:name} label="Name" sort={@list_state.sort} width="30%" />
                  <th scope="col" style="width:16%">Type / Role</th>
                  <.sort_header field={:industry} label="Industry" sort={@list_state.sort} width="16%" />
                  <.sort_header field={:size} label="Size" sort={@list_state.sort} width="14%" />
                  <th scope="col" style="width:16%">Website</th>
                  <th :if={@can_write} scope="col" style="width:8%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={c}>
                  <td class="c-name">
                    <a href={company_path(@samen_mount, @org_id, c.id)} style="display:flex;align-items:center;gap:8px;text-decoration:none">
                      <div class="av" style="width:28px;height:28px;border-radius:6px;background:#E3EDF7;color:#3B4CCA;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                        {company_initials(c.name)}
                      </div>
                      <span style="font-weight:500;color:#3B4CCA">{c.name}</span>
                    </a>
                  </td>
                  <td class="c-role">
                    <.pill variant={role_variant(company_role(c))}>{company_role(c)}</.pill>
                  </td>
                  <td class="c-industry" style="color:var(--muted)">{c.industry || "—"}</td>
                  <td class="c-size" style="color:var(--muted)">{c.size || "—"}</td>
                  <td class="c-website" style="color:var(--muted);font-size:12px">{Map.get(c, :website) || "—"}</td>
                  <td :if={@can_write} class="c-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={c.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and @can_write} id="new-company-modal" title="New company" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-company-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:name]} label="Name" />
              <.form_field field={f[:industry]} label="Industry" />
              <.form_field field={f[:size]} label="Size" />
              <.form_field field={f[:website]} label="Website" type="url" />
              <.form_field field={f[:notes]} label="Notes" type="textarea" />
              <:actions>
                <.button variant="primary" type="submit">Save company</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp crumbs(mount, org_id, leaf) do
    [CurrentOrg.name(mount, org_id), "CRM", leaf]
  end

  defp company_path(mount, org_id, id),
    do: "#{Mount.label(mount, :crm_path, "/crm")}/companies/#{id}?org=#{org_id}"

  defp company_initials(nil), do: "?"

  defp company_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp company_role(company) do
    get_in(company.custom || %{}, ["company_role"]) || "company"
  end

  defp role_variant("carrier"), do: "info"
  defp role_variant("shipper"), do: "ok"
  defp role_variant(_), do: "mut"

  # ADR-036 §4.5(3): the CRM pipeline-value metric is now a Money composite sum.
  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))
  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"
end
