defmodule Samen.Web.CRM.CompanyLive do
  @moduledoc """
  Framework CRM / Company detail (`/crm/companies/:id`) — non-PII (ADR-011 §4.2).

  A tabbed detail page (Overview · Activity · Deals) over the host's `<ns>.Company`, read via
  `Samen.Web.CRM.Reads.get_company/3`. Company carries no PII, so this page renders the same
  on both planes — BUT the log-activity composer is still tenant-plane only (an operator does
  not author into a tenant's timeline). The Contacts sub-list on the Overview tab (this
  company's people) routes through `Reads.contacts_for_company/3`, which IS PII-resolved
  (tenant clear / operator ••••) — never a raw read.

  ## A3 write side — edit + delete + the kit-form composer (AC-G1-1/2)

  "Edit company" opens a `modal/1` hosting an `AshPhoenix.Form.for_update/3`; delete
  carries the `delete_confirm/1` interlock and navigates back to the companies list;
  the log-activity composer is the A2 kit form (`simple_form`/`form_field`, inline
  errors). Company is non-PII — write affordances are still tenant-plane only
  (`Samen.Web.CRM.Live.writable?/1`, the composer posture); the kernel's OrgScope +
  role gates enforce regardless.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live,
    only: [assign_mount: 2, crm_sidebar: 1, writable?: 1, mail_timeline_entries: 1, merge_timeline: 2]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.AccountHealth
  alias Samen.Web.CRM.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    company_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, company_id: company_id, active_tab: "overview", return_to: nil),
       org_id,
       company_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    company_id = Map.get(params, "id") || socket.assigns.company_id
    tab = Map.get(params, "tab") || "overview"

    {:noreply,
     load(
       assign(socket, org_id: org_id, company_id: company_id, active_tab: tab, return_to: return_path(uri)),
       org_id,
       company_id
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  # Log-activity composer — the A2 kit form (AshPhoenix.Form-backed, inline errors).
  # Tenant plane only in the UI; the kernel enforces OrgScope + member gate + SameOrgFk.
  # `company_id`/`org_id`/`status`/`completed_at` are server-side facts, never client input.
  def handle_event("validate_activity", %{"activity" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.activity_form, params)
    {:noreply, assign(socket, activity_form: form)}
  end

  def handle_event("log_activity", %{"activity" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, company_id: company_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    # ADR-041 §6.1: the composer writes a canonical Work Task anchored to this
    # (same-org) company via the generic `(subject_key, subject_id)` object-ref — not a
    # CRM FK. (custom.crm_refs is a migration-only preservation bag; a new single-anchor
    # task needs only the primary anchor — the Tier-1 custom bag rejects unregistered keys.)
    params =
      Map.merge(params, %{
        "status" => "completed",
        "completed_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "subject_key" => "crm.company",
        "subject_id" => company_id,
        "org_id" => org_id
      })

    case AshPhoenix.Form.submit(socket.assigns.activity_form, params: params) do
      {:ok, _task} ->
        {:noreply,
         assign(socket,
           activity_form: activity_form(mount, scope),
           activities: Reads.activities_for_company(mount, scope, company_id)
         )}

      {:error, form} ->
        {:noreply, assign(socket, activity_form: form)}
    end
  end

  # -- A3 edit/delete (non-PII surface) -----------------------------------------

  def handle_event("edit_company", _params, socket) do
    %{samen_mount: mount, org_id: org_id, company: company} = socket.assigns
    scope = Mount.scope(mount, org_id)
    {:noreply, assign(socket, show_edit: true, edit_form: edit_form(company, scope))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, show_edit: false)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.edit_form, params)
    {:noreply, assign(socket, edit_form: form)}
  end

  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _company} ->
        socket = assign(socket, show_edit: false)
        {:noreply, load(socket, socket.assigns.org_id, socket.assigns.company_id)}

      {:error, form} ->
        {:noreply, assign(socket, edit_form: form)}
    end
  end

  # ADR-040 §5.9/T37c: `Company` is `archivable true`, so `Reads.delete_company/3`'s
  # `Ash.destroy/2` now rides the default SOFT destroy (T36) — this sets
  # `archived_at` rather than removing the row, so the company simply drops out of
  # the default (archived-excluding) reads. No cascade is declared for CRM (§5.4),
  # so linked people/opportunities/attachments are untouched and the destroy is
  # never refused on their account; any `{:error, _}` here is a genuine failure
  # (e.g. an authorization denial), not the old FK-refusal case. (Tasks are
  # anchored by a generic object-ref, not a CRM FK, and never blocked either way.)
  def handle_event("delete_company", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.delete_company(mount, scope, id) do
      :ok ->
        {:noreply, push_navigate(socket, to: companies_path(mount, org_id))}

      {:error, _reason} ->
        {:noreply, assign(socket, delete_error: "Could not delete this company.")}
    end
  end

  # T160 (spec §I4 completion) — set/clear this company's billing-account anchor
  # (`Samen.CRM.AccountLink`). Tenant plane only (`writable?/1` gates the form in the
  # render); the kernel enforces org-scope + member role regardless.
  def handle_event("link_billing_customer", %{"billing_customer_id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id, company: company, company_id: company_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.link_billing_customer(mount, scope, company, id) do
      {:ok, _company} ->
        {:noreply, load(assign(socket, link_error: nil), org_id, company_id)}

      {:error, _reason} ->
        {:noreply, assign(socket, link_error: "Could not update the billing link.")}
    end
  end

  @doc false
  def load(socket, nil, _company_id) do
    tab = Map.get(socket.assigns, :active_tab, "overview")

    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      company_id: nil,
      company: nil,
      contacts: [],
      activities: [],
      mail: [],
      deals: [],
      active_tab: tab,
      show_edit: false,
      edit_form: nil,
      activity_form: nil,
      delete_error: nil,
      link_error: nil,
      account_health: nil,
      portfolio_health: nil
    )
  end

  def load(socket, org_id, company_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    company =
      if company_id do
        case Reads.get_company(mount, scope, company_id) do
          {:ok, c} -> c
          :error -> nil
        end
      end

    {activities, mail, deals, contacts} =
      if company do
        {
          Reads.activities_for_company(mount, scope, company_id),
          # T74 §I1: synced mailbox messages (both directions) share this timeline.
          # `[]` when no Mailbox scope is mounted — the honest absence.
          Reads.mail_for_company(mount, scope, company_id),
          Reads.opportunities_for_company(mount, scope, company_id),
          Reads.contacts_for_company(mount, scope, company_id)
        }
      else
        {[], [], [], []}
      end

    tab = Map.get(socket.assigns, :active_tab, "overview")

    # T160 (spec §I4 completion) — THIS company's OWN MRR/health, resolved through its
    # linked Billing.Customer (`Samen.CRM.AccountLink` — a registered anchor,
    # authoritative, with a fail-closed domain-match fallback). Honest absence
    # (`link_status: :unlinked`) when no confident link exists — never a book-wide
    # number rendered under this company's name (the T77 defect this closes). `nil`
    # when no company is loaded.
    account_health = company && AccountHealth.snapshot_for_company(mount, scope, company)

    # T77 (spec §I4) — the org-wide PORTFOLIO totals (across this org's ENTIRE own
    # customer/support book) — kept as a CLEARLY SEPARATED secondary view (see
    # `Samen.Web.AccountHealth`'s moduledoc "T160" section): the per-company panel
    # above is now the default/primary view T160 delivers.
    portfolio_health = AccountHealth.snapshot(mount, scope)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      company_id: company_id,
      company: company,
      contacts: contacts,
      activities: activities,
      mail: mail,
      deals: deals,
      active_tab: tab,
      edit_form: company && edit_form(company, scope),
      activity_form: activity_form(mount, scope),
      delete_error: nil,
      link_error: nil,
      account_health: account_health,
      portfolio_health: portfolio_health
    )
    |> assign_new(:show_edit, fn -> false end)
  end

  defp edit_form(company, scope) do
    company
    |> AshPhoenix.Form.for_update(:update, scope: scope)
    |> to_form()
  end

  # The composer writes a canonical Work Task (ADR-041 §6.1); the Task resource is
  # derived from this CRM mount's host root (Reads.work_task_resource/1).
  defp activity_form(mount, scope) do
    Reads.work_task_resource(mount)
    |> AshPhoenix.Form.for_create(:create, scope: scope, as: "activity")
    |> to_form()
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-company">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_companies} return_to={@return_to} />
        </:sidebar>

        <.topbar title={company_name(@company)} crumbs={crumbs(@samen_mount, @org_id, company_name(@company))}>
          <:actions>
            <a href={companies_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">
              <span class="i">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </span>
              Back to companies
            </a>
            <.button :if={writable?(@samen_mount) and @company != nil} phx-click="edit_company" id="edit-company">
              Edit company
            </.button>
            <.delete_confirm
              :if={writable?(@samen_mount) and @company != nil}
              id="delete-company"
              message="Delete this company? This cannot be undone."
              phx-click="delete_company"
              phx-value-id={@company && @company.id}
            />
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <%= if @company == nil do %>
            <div class="wrap">
              <div class="card" style="padding:22px 20px;color:var(--muted)">Company not found.</div>
            </div>
          <% else %>
            <div class="wrap" style="margin-bottom:0">
              <div class="card" id="company-header" style="padding:18px 20px;display:flex;align-items:center;gap:14px;flex-wrap:wrap">
                <div class="av" style="width:46px;height:46px;border-radius:8px;background:#E3EDF7;color:#3B4CCA;font-size:15px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                  {company_initials(@company.name)}
                </div>
                <div style="flex:1;min-width:0">
                  <h1 class="c-company-name" style="font-weight:600;font-size:18px;color:#2a2b35;margin:0 0 4px">{@company.name}</h1>
                  <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
                    <.pill :if={@company.industry} variant="info">{@company.industry}</.pill>
                    <.pill :if={@company.size} variant="mut">{@company.size}</.pill>
                    <.pill :if={company_role(@company)} variant="ok">{company_role(@company)}</.pill>
                    <span :if={@company.website} style="font-size:12px;color:var(--muted)">{@company.website}</span>
                  </div>
                </div>
              </div>
            </div>

            <!-- T160 (spec §I4 completion) — the REAL per-company panel: THIS company's OWN
                 MRR/health, resolved through its linked Billing.Customer. Default/primary
                 view (the "unfair advantage" spec §I4 asks for). -->
            <div class="wrap" style="margin-bottom:0;padding-top:10px" id="account-health-panel">
              <div class="metrics">
                <div id="account-mrr">
                  <.metric label="MRR" value={account_mrr_value(@account_health)} sub={account_mrr_sub(@account_health)}>
                    <:icon>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                        <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                      </svg>
                    </:icon>
                  </.metric>
                </div>
                <div id="account-health-score">
                  <.metric label="Account health" value={account_health_value(@account_health)} sub={account_health_sub(@account_health)}>
                    <:icon>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                        <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
                      </svg>
                    </:icon>
                  </.metric>
                </div>
                <div id="account-support-load">
                  <.metric label="Open support tickets" value={account_support_value(@account_health)} sub={account_support_sub(@account_health)}>
                    <:icon>
                      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                      </svg>
                    </:icon>
                  </.metric>
                </div>
              </div>
              <div class="lane" id="account-health-disclosure" style="font-size:11px;color:var(--muted);padding:4px 2px 0">
                {account_health_disclosure(@account_health)}
              </div>
              <div :if={@link_error} class="card form-error" id="link-error" style="margin-top:6px;padding:6px 10px;color:var(--bad, #b91c1c);font-size:11px">
                {@link_error}
              </div>
              <form
                :if={writable?(@samen_mount)}
                id="link-billing-customer-form"
                phx-submit="link_billing_customer"
                style="margin-top:6px;display:flex;gap:6px;align-items:center"
              >
                <input
                  type="text"
                  name="billing_customer_id"
                  value={account_health_anchor_value(@account_health)}
                  placeholder="Billing customer ID — paste to link (blank clears the anchor)"
                  style="font-size:11px;padding:4px 6px;flex:1;max-width:360px"
                />
                <.button type="submit" id="link-billing-customer-submit">Link</.button>
              </form>
            </div>

            <!-- T77 (spec §I4) — the org-wide PORTFOLIO view, kept as a CLEARLY SEPARATED
                 secondary panel (see AccountHealth's "T160" moduledoc section). -->
            <div class="wrap" style="margin-bottom:0;padding-top:8px" id="portfolio-health-panel">
              <details>
                <summary style="cursor:pointer;font-size:12px;color:var(--muted)">Portfolio view — totals across ALL of this org's customers</summary>
                <div class="metrics" style="margin-top:8px">
                  <div id="portfolio-mrr">
                    <.metric
                      label="Total MRR — all customers"
                      value={portfolio_mrr_value(@portfolio_health)}
                      sub={portfolio_mrr_sub(@portfolio_health)}
                    >
                      <:icon>
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                          <path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" />
                        </svg>
                      </:icon>
                    </.metric>
                  </div>
                  <div id="portfolio-health-score">
                    <.metric
                      label="Portfolio health"
                      value={portfolio_health_value(@portfolio_health)}
                      sub={portfolio_health_sub(@portfolio_health)}
                    >
                      <:icon>
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                          <path d="M22 12h-4l-3 9L9 3l-3 9H2" />
                        </svg>
                      </:icon>
                    </.metric>
                  </div>
                  <div id="portfolio-support-load">
                    <.metric
                      label="Open support tickets — all customers"
                      value={portfolio_support_value(@portfolio_health)}
                      sub={portfolio_support_sub(@portfolio_health)}
                    >
                      <:icon>
                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                          <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
                        </svg>
                      </:icon>
                    </.metric>
                  </div>
                </div>
                <div class="lane" id="portfolio-health-disclosure" style="font-size:11px;color:var(--muted);padding:4px 2px 0">
                  org-wide totals across this org's ENTIRE customer &amp; support book (spec §I4) — NOT this specific company's numbers; link this company to a billing account above for its OWN numbers
                </div>
              </details>
            </div>

            <div class="wrap" style="margin-bottom:0;padding-top:8px">
              <.tabs>
                <.tab label="Overview" href={"?org=#{@org_id}&tab=overview"} active={@active_tab == "overview"} />
                <.tab label="Activity" href={"?org=#{@org_id}&tab=activity"} active={@active_tab == "activity"} />
                <.tab label="Deals" href={"?org=#{@org_id}&tab=deals"} active={@active_tab == "deals"} />
              </.tabs>
            </div>

            <%= case @active_tab do %>
              <% "activity" -> %>
                <div class="wrap" id="activity-pane">
                  <div class="card" style="padding:8px 4px 12px">
                    <.timeline
                      entries={merge_timeline(timeline_entries(@activities), mail_timeline_entries(@mail))}
                      empty="No activity yet — log the first call or note below."
                    >
                      <:composer :if={composer?(@samen_mount)}>
                        {activity_composer(assigns)}
                      </:composer>
                    </.timeline>
                  </div>
                </div>
              <% "deals" -> %>
                <div class="wrap" id="deals-pane">
                  <%= if @deals == [] do %>
                    <.empty_state
                      class="deals-empty"
                      icon="◇"
                      title="No deals yet."
                      body="Deals for this company appear here — start one from the Pipeline."
                    />
                  <% else %>
                    <.data_table>
                      <:head>
                        <th style="width:50%">Deal</th>
                        <th style="width:22%">Stage</th>
                        <th style="width:14%">Status</th>
                        <th style="width:14%">Value</th>
                      </:head>
                      <tr :for={opp <- @deals} class="deal-row" id={"deal-#{opp.id}"}>
                        <td style="font-weight:500;color:#3a3b45">{opp.name}</td>
                        <td style="color:var(--muted)">{stage_label(opp)}</td>
                        <td><.pill variant={opp_status_variant(opp.status)}>{opp.status}</.pill></td>
                        <td style="color:var(--muted)">{dollars(opp.value)}</td>
                      </tr>
                    </.data_table>
                  <% end %>
                </div>
              <% _ -> %>
                <div class="wrap" id="overview-pane">
                  <div class="card" style="padding:20px">
                    <div class="gtitle" style="margin-bottom:16px"><h3>Company details</h3></div>
                    <table style="width:100%;font-size:13px;border-collapse:collapse">
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted);width:160px">Industry</td>
                        <td style="padding:10px 0">{@company.industry || "—"}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Size</td>
                        <td style="padding:10px 0">{@company.size || "—"}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Website</td>
                        <td style="padding:10px 0">{@company.website || "—"}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Domain</td>
                        <td style="padding:10px 0">{Map.get(@company, :domain) || "—"}</td>
                      </tr>
                      <tr :if={company_role(@company)} style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Role</td>
                        <td style="padding:10px 0">{company_role(@company)}</td>
                      </tr>
                    </table>

                    <%= if @contacts != [] do %>
                      <div class="gtitle" style="margin:20px 0 12px"><h3>Contacts <small style="font-weight:400;color:var(--muted)">(🔒 PII resolved per plane)</small></h3></div>
                      <.data_table>
                        <:head>
                          <th style="width:40%">Name</th>
                          <th style="width:36%">Email</th>
                          <th style="width:24%">Title</th>
                        </:head>
                        <tr :for={p <- @contacts} class="cc-contact-row" id={"cc-contact-#{p.id}"}>
                          <td>
                            <a href={contact_path(@samen_mount, @org_id, p.id)} style="font-weight:500;color:#3B4CCA;text-decoration:none">
                              {render_full_name(p.full_name, p.display_name)}
                            </a>
                          </td>
                          <td style="font-size:12px;color:var(--muted)">{render_email(p.emails)}</td>
                          <td style="font-size:12px;color:var(--muted)">{p.job_title || "—"}</td>
                        </tr>
                      </.data_table>
                    <% end %>
                  </div>
                </div>
            <% end %>

            <.modal :if={@show_edit and @edit_form != nil and writable?(@samen_mount)} id="edit-company-modal" title="Edit company" on_cancel="cancel_edit">
              <.simple_form :let={f} for={@edit_form} id="edit-company-form" phx-change="validate_edit" phx-submit="save_edit">
                <.form_field field={f[:name]} label="Name" />
                <.form_field field={f[:industry]} label="Industry" />
                <.form_field field={f[:size]} label="Size" />
                <.form_field field={f[:website]} label="Website" type="url" />
                <.form_field field={f[:notes]} label="Notes" type="textarea" />
                <:actions>
                  <.button variant="primary" type="submit">Save company</.button>
                  <.button type="button" phx-click="cancel_edit">Cancel</.button>
                </:actions>
              </.simple_form>
            </.modal>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # The log-activity composer (tenant plane only) — the A2 kit form: AshPhoenix.Form-
  # backed simple_form/form_field with inline errors (AC-G1-2). Non-PII fields.
  defp activity_composer(assigns) do
    ~H"""
    <div style="padding:14px 16px;border-bottom:1px solid var(--border)">
      <.simple_form :let={f} for={@activity_form} id="log-activity-form" phx-change="validate_activity" phx-submit="log_activity">
        <.form_field
          field={f[:kind]}
          label="Type"
          type="select"
          options={[{"Note", "note"}, {"Call", "call"}, {"Email", "email"}, {"Meeting", "meeting"}, {"Task", "task"}]}
        />
        <.form_field field={f[:title]} label="Subject" placeholder="Subject" />
        <.form_field field={f[:body]} label="Details" type="textarea" rows="2" placeholder="Details…" />
        <:actions>
          <.button variant="primary" type="submit">Log activity</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "CRM", "Companies", leaf]

  defp composer?(%Mount{plane: %{kind: :operator}}), do: false
  defp composer?(_), do: true

  defp companies_path(mount, org_id), do: "#{crm_path(mount)}/companies?org=#{org_id}"
  defp contact_path(mount, org_id, id), do: "#{crm_path(mount)}/contacts/#{id}?org=#{org_id}"
  defp crm_path(mount), do: Mount.label(mount, :crm_path, "/crm")

  defp company_name(nil), do: "Company"
  defp company_name(%{name: name}), do: name

  defp company_initials(nil), do: "?"

  defp company_initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

  defp company_role(%{custom: custom}) when is_map(custom), do: Map.get(custom, "company_role")
  defp company_role(_), do: nil

  # -- T160 (spec §I4 completion) per-COMPANY panel renderers --------------------
  #
  # THIS company's OWN numbers, resolved through `Samen.CRM.AccountLink` — see
  # `Samen.Web.AccountHealth.snapshot_for_company/3`'s moduledoc. Honest absence
  # (`link_status: :unlinked`) renders "—", NEVER a book-wide number under this
  # company's name (the T77 defect this closes) and NEVER a fabricated `$0.00`.

  defp account_mrr_value(%{link_status: :unlinked}), do: "—"
  defp account_mrr_value(%{billing_available?: false}), do: "—"
  defp account_mrr_value(%{mrr_cents: cents}) when is_integer(cents), do: dollars(cents)
  defp account_mrr_value(_), do: "—"

  defp account_mrr_sub(%{link_status: :unlinked}), do: "not linked to a billing account yet"
  defp account_mrr_sub(%{billing_available?: false}), do: "billing not configured for this app"
  defp account_mrr_sub(%{subscription_status: nil}), do: "no subscription on file for this account"

  defp account_mrr_sub(%{subscription_status: status, active_subs: n}),
    do: "#{n} active subscription(s) · status: #{status}"

  defp account_mrr_sub(_), do: "—"

  defp account_health_value(%{link_status: :unlinked}), do: "—"
  defp account_health_value(%{health: nil}), do: "—"
  defp account_health_value(%{health: %AccountHealth{score: nil}}), do: "—"
  defp account_health_value(%{health: %AccountHealth{score: score}}), do: "#{score} / 100"
  defp account_health_value(_), do: "—"

  defp account_health_sub(%{link_status: :unlinked}), do: "no signal — link this company to a billing account"
  defp account_health_sub(%{health: nil}), do: "no billing signal available"
  defp account_health_sub(%{health: %AccountHealth{band: band}}), do: health_band_label(band)
  defp account_health_sub(_), do: "no billing signal available"

  defp health_band_label(:healthy), do: "healthy"
  defp health_band_label(:watch), do: "watch"
  defp health_band_label(:at_risk), do: "at risk"
  defp health_band_label(:critical), do: "critical"
  defp health_band_label(_), do: "no signal"

  # Support carries NO structural per-account link in this substrate (see
  # `AccountHealth`'s moduledoc — `Ticket` has no `customer_id`/`company_id`) — the
  # per-company tile is ALWAYS honest absence, distinct copy from "not configured" so
  # it doesn't read as a bug.
  defp account_support_value(_), do: "—"
  defp account_support_sub(_), do: "not linked to individual accounts in this build — see the portfolio view below"

  defp account_health_disclosure(%{link_status: :anchor}) do
    "linked via a registered billing-account anchor on this company — MRR/health reflect THIS company's own " <>
      "billing customer only. Support tickets remain portfolio-only (see below) — this substrate has no " <>
      "per-account ticket link yet."
  end

  defp account_health_disclosure(%{link_status: :domain}) do
    "linked by a confident, fail-closed domain match against this org's billing customers (no anchor set yet) — " <>
      "MRR/health reflect THIS company's own billing customer only. Support tickets remain portfolio-only " <>
      "(see below)."
  end

  defp account_health_disclosure(%{link_status: :unlinked}) do
    "this company isn't linked to a billing account yet — set an anchor below, or a confident domain match will " <>
      "link it automatically. No numbers are shown until a link is confident: never a guess, never a book-wide " <>
      "total under this company's name."
  end

  defp account_health_disclosure(_), do: "this company isn't linked to a billing account yet."

  defp account_health_anchor_value(%{link_status: :anchor, billing_customer_id: id}) when is_binary(id), do: id
  defp account_health_anchor_value(_), do: ""

  # -- T77 (spec §I4) PORTFOLIO panel renderers (secondary, clearly separated) ---
  #
  # PORTFOLIO totals across this org's ENTIRE customer/support book — see
  # `Samen.Web.AccountHealth`'s moduledoc. Every label/sub-copy below says "all
  # customers"/"across the book" so nobody reads these tiles as this-specific-
  # company's numbers.
  #
  # Honest-absence discipline: `billing_available?`/`support_available?` false means
  # EITHER the scope is not MOUNTED for this host, OR the underlying read genuinely
  # FAILED (fix round 1, MED-3 — see `AccountHealth.billing_snapshot/2`'s canary read)
  # — rendered "—", NEVER a fabricated `$0.00` or `0`. When a scope IS mounted and the
  # read genuinely SUCCEEDS with nothing in it, the real zero renders (a true DB
  # aggregate, not a fabrication).

  defp portfolio_mrr_value(%{billing_available?: false}), do: "—"
  defp portfolio_mrr_value(%{mrr_cents: cents}), do: dollars(cents)
  defp portfolio_mrr_value(_), do: "—"

  defp portfolio_mrr_sub(%{billing_available?: false}), do: "billing not configured for this app"
  defp portfolio_mrr_sub(%{subscription_status: nil}), do: "no subscriptions on file across this org's customers"

  defp portfolio_mrr_sub(%{subscription_status: status, active_subs: n}),
    do: "#{n} active subscription(s) · worst status in book: #{status}"

  defp portfolio_mrr_sub(_), do: "—"

  defp portfolio_health_value(%{health: nil}), do: "—"
  defp portfolio_health_value(%{health: %AccountHealth{score: nil}}), do: "—"
  defp portfolio_health_value(%{health: %AccountHealth{score: score}}), do: "#{score} / 100"
  defp portfolio_health_value(_), do: "—"

  defp portfolio_health_sub(%{health: nil}), do: "no billing or support signal available"
  defp portfolio_health_sub(%{health: %AccountHealth{band: band}}), do: health_band_label(band)
  defp portfolio_health_sub(_), do: "no billing or support signal available"

  defp portfolio_support_value(%{support_available?: false}), do: "—"
  defp portfolio_support_value(%{open_tickets: n}) when is_integer(n), do: n
  defp portfolio_support_value(_), do: "—"

  defp portfolio_support_sub(%{support_available?: false}), do: "support not configured for this app"
  defp portfolio_support_sub(%{breaching_sla: 0}), do: "none breaching SLA, across all customers"
  defp portfolio_support_sub(%{breaching_sla: n}) when is_integer(n), do: "#{n} breaching SLA, across all customers"
  defp portfolio_support_sub(_), do: "—"

  # Project the Work Task onto the EXISTING timeline entry keys (ADR-041 §6.1):
  # kind → :type, title → :subject, completed_at||inserted_at → :at. The presentational
  # timeline component is unchanged.
  defp timeline_entries(tasks) do
    Enum.map(tasks, fn t ->
      %{
        id: t.id,
        type: t.kind,
        subject: t.title,
        body: t.body,
        status: t.status,
        at: t.completed_at || Map.get(t, :inserted_at),
        who: task_author(t)
      }
    end)
  end

  defp task_author(%{custom: custom}) when is_map(custom), do: Map.get(custom, "author")
  defp task_author(_), do: nil

  defp stage_label(%{__stage__: %{label: label}}) when is_binary(label), do: label
  defp stage_label(%{__stage__: %{name: name}}) when is_binary(name), do: name
  defp stage_label(_), do: "—"

  defp opp_status_variant(:open), do: "info"
  defp opp_status_variant(:won), do: "ok"
  defp opp_status_variant(:lost), do: "bad"
  defp opp_status_variant(:on_hold), do: "warn"
  defp opp_status_variant(_), do: "mut"

  # ADR-036 §4.5(3): opp.value is now the Money composite (dollars(opp.value)).
  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))
  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "$0.00"

  # PII renderers for the company's contacts sub-list (render %Masked{} as-is).

  defp render_full_name(%Samen.Masked{} = masked, _display_name), do: masked

  defp render_full_name(name, _display_name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  defp render_full_name(nil, display_name) when is_binary(display_name), do: display_name
  defp render_full_name(nil, _display_name), do: "—"
  defp render_full_name(other, _display_name), do: other

  defp render_email(%Samen.Masked{} = masked), do: masked
  defp render_email(%Samen.Type.Emails{entries: entries}), do: render_email(entries)

  defp render_email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_email(list)
      _ -> "—"
    end
  end

  defp render_email(emails) when is_list(emails) do
    case List.first(emails) do
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      _ -> "—"
    end
  end

  defp render_email(_), do: "—"
end
