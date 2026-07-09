defmodule Samen.Web.Operator.AccountsLive do
  @moduledoc """
  Framework OPERATOR / Accounts page (ADR-010 §4a) — the operator CRM where each account IS a
  tenant org. Reads `Identity.Org` rows (operator namespace, operator-org-scoped) as ACCOUNTS,
  each joined to its admin `Identity.User`s (the tenant-ADMINS — PII CLEAR, the SaaS's own
  signup contacts), its subscription-to-the-SaaS (plan/MRR/status), a seat proxy, and its open
  desk-ticket count.

  ## The identity line, clear side (ADR-010 §5)

  This page reads the OPERATOR ORG's OWN book of business on the TENANT plane
  (`Samen.Web.Operator.scope/1`). The tenant-admin's name/email render IN THE CLEAR because the
  `plane: :tenant` resolver clears own-org PII — the SaaS owns this data. The tenant's DOWNSTREAM
  end-customers are NOT read here; "Open account" LINKS to the ADR-009 impersonation surface
  (`plane: :operator`, masked) via the `tenant_org_id` back-reference. This LiveView NEVER calls
  the vault, NEVER unwraps a `%Masked{}`, and has NO plaintext branch.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    mount = socket.assigns[:samen_mount]
    operator_org_id = mount && Operator.org_id(mount)

    case operator_org_id do
      nil ->
        assign(socket, no_org: true, operator_org_id: nil, accounts: [], metrics: nil)

      org_id ->
        scope = Operator.scope(mount)

        assign(socket,
          no_org: false,
          operator_org_id: org_id,
          accounts: Reads.accounts(mount, scope, org_id),
          metrics: Reads.account_metrics(mount, scope, org_id)
        )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-accounts">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:accounts} />
        </:sidebar>

        <.topbar title="Accounts" crumbs={["Operator plane", "Accounts"]}>
          <:actions>
            <.button variant="primary">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New account
            </.button>
          </:actions>
        </.topbar>

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No operator org resolved. Seed the operator org or configure
              <code>operator_org_id</code>.
            </div>
          </div>
        <% else %>
          <div class="metrics">
            <.metric label="Accounts" value={@metrics && @metrics.accounts || 0} sub="tenant orgs">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Healthy" value={@metrics && @metrics.active || 0} sub="active subscriptions">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M20 6 9 17l-5-5" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="At risk" value={@metrics && @metrics.at_risk || 0} sub="past-due / dunning">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 9v4M12 17h.01M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" />
                </svg>
              </:icon>
            </.metric>
            <.metric label="Platform MRR" value={dollars((@metrics && @metrics.mrr_cents) || 0)} sub="across accounts">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <div id="accounts">
              <div class="gtitle">
                <h3>Accounts</h3>
                <span class="n">{length(@accounts)}</span>
                <span class="lane">· each account IS a tenant org · primary contact (tenant-admin) in the clear</span>
              </div>
              <.data_table>
                <:head>
                  <th style="width:24%">Account</th>
                  <th style="width:22%">Primary contact</th>
                  <th style="width:20%">Email</th>
                  <th style="width:10%">Plan</th>
                  <th style="width:8%">Health</th>
                  <th style="width:8%">Seats</th>
                  <th style="width:8%">MRR</th>
                </:head>
                <tr :for={a <- @accounts} class="account-row" id={"account-#{a.id}"}>
                  <td class="a-name">
                    <div style="display:flex;align-items:center;gap:8px">
                      <div class="av" style="width:28px;height:28px;border-radius:6px;background:#DDE2F5;color:#3B4CCA;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                        {account_initials(a.name)}
                      </div>
                      <div>
                        <span style="font-weight:500;color:#3a3b45">{a.name}</span>
                        <div :if={a.tenant_org_id} style="display:flex;gap:10px;font-size:11px">
                          <a
                            class="open-account"
                            href={open_account_href(@samen_mount, a.tenant_org_id)}
                            style="color:#3B4CCA"
                            title="Act as this tenant on the TENANT plane (clear) — fill out / QA the demo"
                          >
                            Open account →
                          </a>
                          <a
                            class="impersonate-account"
                            href={impersonate_href(@samen_mount, a.tenant_org_id)}
                            style="color:var(--muted)"
                            title="Impersonate on the OPERATOR plane (masked) — the support drill-in"
                          >
                            Impersonate (masked) →
                          </a>
                        </div>
                      </div>
                    </div>
                  </td>
                  <td class="a-contact" style="font-weight:500;color:#3a3b45">
                    {primary_contact_name(a.__admins__)}
                  </td>
                  <td class="a-email" style="font-size:12px;color:var(--muted)">
                    {primary_contact_email(a.__admins__)}
                  </td>
                  <td class="a-plan" style="color:var(--muted)">{a.plan || "—"}</td>
                  <td class="a-health">
                    <.pill variant={health_variant(a.__health__)}>{health_label(a.__health__)}</.pill>
                  </td>
                  <td class="a-seats" style="color:var(--muted)">{a.__seats__}</td>
                  <td class="a-mrr" style="color:var(--muted)">{dollars(a.__mrr_cents__)}</td>
                </tr>
              </.data_table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- entry helpers (ADR-013 §5.2 — two clean grades of drill-in) --------------

  # (1) Act-as / CLEAR — set the session current org via the framework SessionController and
  # land in the tenant's workspace on the TENANT plane. The tenant landing path is a mount
  # label (`:tenant_landing`, default `/broker`) so a host lands you on its own home page.
  defp open_account_href(mount, tenant_org_id) do
    landing = Samen.Web.Mount.label(mount, :tenant_landing, "/broker")
    "/session/org/#{tenant_org_id}?return_to=#{URI.encode_www_form(landing)}"
  end

  # (2) Impersonate / MASKED — the EXISTING operator-plane impersonation drill-in (ADR-009/010),
  # a host-supplied path (`:impersonate_path` label, default `/operator/impersonate`) carrying
  # the tenant org via `?org=`. The plane (not the session) is what masks.
  defp impersonate_href(mount, tenant_org_id) do
    path = Samen.Web.Mount.label(mount, :impersonate_path, "/operator/impersonate")
    "#{path}?org=#{tenant_org_id}"
  end

  # -- helpers -----------------------------------------------------------------

  defp primary_contact_name([admin | _]), do: render_name(admin.full_name)
  defp primary_contact_name(_), do: "—"

  defp primary_contact_email([admin | _]), do: render_email(admin.emails)
  defp primary_contact_email(_), do: "—"

  defp account_initials(nil), do: "?"

  defp account_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp health_variant(:healthy), do: "ok"
  defp health_variant(:at_risk), do: "warn"
  defp health_variant(:churned), do: "bad"
  defp health_variant(_), do: "mut"

  defp health_label(:healthy), do: "healthy"
  defp health_label(:at_risk), do: "at risk"
  defp health_label(:churned), do: "churned"
  defp health_label(_), do: "unknown"
end
