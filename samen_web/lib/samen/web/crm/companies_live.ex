defmodule Samen.Web.CRM.CompaniesLive do
  @moduledoc """
  Framework CRM / Companies page — the inherited CRM domain rendered as real UI,
  host-agnostic (ADR-009). Reads the host's `<namespace>.Company` via
  `Samen.Web.CRM.Reads.companies/2`, parameterized by the `Samen.Web.Mount` threaded
  through the `live_session` session. Companies are non-PII.

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
  alias Samen.Web.Mount

  alias Samen.Web.CRM.Reads

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
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil, companies: [], metrics: nil)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      companies: Reads.companies(mount, scope),
      metrics: Reads.metrics(mount, scope)
    )
  end

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
            <.button variant="primary">
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

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Companies" value={@metrics && @metrics.companies || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Contacts" value={@metrics && @metrics.contacts || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="8" r="3.2" /><path d="M5 20c0-3.5 3-6 7-6s7 2.5 7 6" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Open opportunities" value={@metrics && @metrics.open_opps || 0}>
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" />
                </svg>
              </:icon>
            </.metric>
            <.metric
              label="Pipeline value"
              value={dollars((@metrics && @metrics.pipeline_value_cents) || 0)}
              sub="open opportunities"
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
                <span class="n">{length(@companies)}</span>
                <span class="lane">· org-scoped · no PII</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:32%">Name</th>
                  <th style="width:18%">Type / Role</th>
                  <th style="width:18%">Industry</th>
                  <th style="width:16%">Size</th>
                  <th style="width:16%">Website</th>
                </:head>
                <tr :for={c <- @companies} class="company-row" id={"company-#{c.id}"}>
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
                </tr>
              </.data_table>
            </div>
          </div>
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

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"
end
