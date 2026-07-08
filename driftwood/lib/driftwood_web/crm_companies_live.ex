defmodule DriftwoodWeb.CrmCompaniesLive do
  @moduledoc """
  CRM / Companies page — the inherited CRM domain, rendered as real UI.

  Reads `Driftwood.Crm.Company` through `Driftwood.CrmReads.companies/1` on the
  TENANT plane (plane: :tenant). Companies are non-PII — no vault-routed fields
  — so no PiiResolution step is needed. The page shows a data_table of companies
  plus metric cards (companies, contacts, open opportunities, pipeline value).

  Org-scoped: the read policy on `Driftwood.Crm.Company` requires an org_id match
  via `Samen.Policy.OrgScope`, so a broker sees ONLY their own org's companies.

  ## Plane / PII note

  Company has no PII fields. The metric cards call `CrmReads.metrics/1` which
  counts Person records (contacts) — counts are non-PII integers, not PII values.
  """
  use Phoenix.LiveView

  import DriftwoodWeb.UIKit

  alias Driftwood.CrmReads

  @impl true
  def mount(params, _session, socket) do
    org_id = Map.get(params, "org")
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id), org_id)}
  end

  @doc false
  def load(socket, nil) do
    assign(socket, no_org: true, org_id: nil, companies: [], metrics: nil)
  end

  def load(socket, org_id) do
    scope = crm_scope(org_id)

    assign(socket,
      no_org: false,
      org_id: org_id,
      companies: CrmReads.companies(scope),
      metrics: CrmReads.metrics(scope)
    )
  end

  # A tenant-member scope for CRM reads: plane: :tenant so the org reads its OWN
  # data in the clear (OrgScope narrows to the org; no PII on Company itself).
  @doc false
  def crm_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "broker:#{org_id}",
        org_id: org_id,
        role: :member,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-companies">
      <.app_shell>
        <:sidebar>
          {crm_sidebar(assigns)}
        </:sidebar>

        <.topbar title="Companies" crumbs={["Blue Ridge Logistics", "CRM", "Companies"]}>
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

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No org selected. Append <code>?org=&lt;uuid&gt;</code> to the URL.
            </div>
          </div>
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
                    <div style="display:flex;align-items:center;gap:8px">
                      <div class="av" style="width:28px;height:28px;border-radius:6px;background:#E3EDF7;color:#3B4CCA;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                        {company_initials(c.name)}
                      </div>
                      <span style="font-weight:500;color:#3a3b45">{c.name}</span>
                    </div>
                  </td>
                  <td class="c-role">
                    <.pill variant={role_variant(company_role(c))}>{company_role(c)}</.pill>
                  </td>
                  <td class="c-industry" style="color:var(--muted)">{c.industry || "—"}</td>
                  <td class="c-size" style="color:var(--muted)">{c.size || "—"}</td>
                  <td class="c-website" style="color:var(--muted);font-size:12px">{c.website || "—"}</td>
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

  # Shared CRM sidebar — active on the companies page.
  defp crm_sidebar(assigns) do
    ~H"""
    <.sidebar
      title="Blue Ridge Logistics"
      subtitle="CRM"
      logo="B"
      logo_style="background:linear-gradient(150deg,#0E7C5A,#17A06E)"
    >
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search companies, contacts…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.module_nav org_id={@org_id} active={:crm_companies} />

      <:footer>
        <div class="foot">
          <div class="av" style="background:#D6E9DF;color:#1E7A45">RM</div>
          <div class="m"><b>Rosa Medina</b><span>dispatcher</span></div>
        </div>
      </:footer>
    </.sidebar>
    """
  end
end
