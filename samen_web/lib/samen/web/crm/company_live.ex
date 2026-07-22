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
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

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

    params =
      Map.merge(params, %{
        "status" => "completed",
        "completed_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "company_id" => company_id,
        "org_id" => org_id
      })

    case AshPhoenix.Form.submit(socket.assigns.activity_form, params: params) do
      {:ok, _activity} ->
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

  # FAIL-HONEST delete: navigate away ONLY when the destroy actually happened. The
  # kernel defines no cascade — a company with linked people/deals/activities is
  # refused by the DB (FK) and the refusal is SURFACED, never a silent no-op.
  def handle_event("delete_company", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.delete_company(mount, scope, id) do
      :ok ->
        {:noreply, push_navigate(socket, to: companies_path(mount, org_id))}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           delete_error:
             "Could not delete this company — it still has linked records (contacts, deals, or activities)."
         )}
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
      deals: [],
      active_tab: tab,
      show_edit: false,
      edit_form: nil,
      activity_form: nil,
      delete_error: nil
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

    {activities, deals, contacts} =
      if company do
        {
          Reads.activities_for_company(mount, scope, company_id),
          Reads.opportunities_for_company(mount, scope, company_id),
          Reads.contacts_for_company(mount, scope, company_id)
        }
      else
        {[], [], []}
      end

    tab = Map.get(socket.assigns, :active_tab, "overview")

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      company_id: company_id,
      company: company,
      contacts: contacts,
      activities: activities,
      deals: deals,
      active_tab: tab,
      edit_form: company && edit_form(company, scope),
      activity_form: activity_form(mount, scope),
      delete_error: nil
    )
    |> assign_new(:show_edit, fn -> false end)
  end

  defp edit_form(company, scope) do
    company
    |> AshPhoenix.Form.for_update(:update, scope: scope)
    |> to_form()
  end

  defp activity_form(mount, scope) do
    Mount.resource(mount, Activity)
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
                    <.timeline entries={timeline_entries(@activities)} empty="No activity yet — log the first call or note below.">
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
          field={f[:type]}
          label="Type"
          type="select"
          options={[{"Note", "note"}, {"Call", "call"}, {"Email", "email"}, {"Meeting", "meeting"}, {"Task", "task"}]}
        />
        <.form_field field={f[:subject]} label="Subject" placeholder="Subject" />
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

  defp timeline_entries(activities) do
    Enum.map(activities, fn a ->
      %{
        id: a.id,
        type: a.type,
        subject: a.subject,
        body: a.body,
        status: a.status,
        at: a.completed_at || Map.get(a, :inserted_at),
        who: activity_author(a)
      }
    end)
  end

  defp activity_author(%{custom: custom}) when is_map(custom), do: Map.get(custom, "author")
  defp activity_author(_), do: nil

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
