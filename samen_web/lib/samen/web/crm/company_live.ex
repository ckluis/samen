defmodule Samen.Web.CRM.CompanyLive do
  @moduledoc """
  Framework CRM / Company detail (`/crm/companies/:id`) — non-PII (ADR-011 §4.2).

  A tabbed detail page (Overview · Activity · Deals) over the host's `<ns>.Company`, read via
  `Samen.Web.CRM.Reads.get_company/3`. Company carries no PII, so this page renders the same
  on both planes — BUT the log-activity composer is still tenant-plane only (an operator does
  not author into a tenant's timeline). The Contacts sub-list on the Overview tab (this
  company's people) routes through `Reads.contacts_for_company/3`, which IS PII-resolved
  (tenant clear / operator ••••) — never a raw read.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.CRM.Reads

  @activity_types ~w(note call email meeting task)

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    company_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, company_id: company_id, active_tab: "overview", form_error: nil, return_to: nil),
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

  def handle_event("log_activity", %{"activity" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, company_id: company_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    attrs = %{
      type: activity_type(params["type"]),
      subject: nz(params["subject"]),
      body: nz(params["body"]),
      status: :completed,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      company_id: company_id,
      org_id: org_id
    }

    case Reads.create_activity(mount, scope, attrs) do
      {:ok, _activity} ->
        {:noreply,
         assign(socket,
           form_error: nil,
           activities: Reads.activities_for_company(mount, scope, company_id)
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, form_error: "Could not log the activity. Check the fields and try again.")}
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
      form_error: nil
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
      form_error: Map.get(socket.assigns, :form_error)
    )
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
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">CRM org: {@org_id}</span>

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
                    <div class="card" style="padding:22px 20px;color:var(--muted)">No deals for this company yet.</div>
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
                        <td style="color:var(--muted)">{dollars(opp.value_cents)}</td>
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
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp activity_composer(assigns) do
    ~H"""
    <form id="log-activity-form" phx-submit="log_activity" style="padding:14px 16px;border-bottom:1px solid var(--border);display:flex;flex-direction:column;gap:8px">
      <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
        <select name="activity[type]" style="padding:7px 10px;border:1px solid var(--border);border-radius:6px;font-size:13px">
          <option value="note">Note</option>
          <option value="call">Call</option>
          <option value="email">Email</option>
          <option value="meeting">Meeting</option>
          <option value="task">Task</option>
        </select>
        <input
          type="text"
          name="activity[subject]"
          placeholder="Subject"
          style="flex:1;min-width:200px;padding:7px 10px;border:1px solid var(--border);border-radius:6px;font-size:13px"
        />
      </div>
      <textarea
        name="activity[body]"
        placeholder="Details…"
        rows="2"
        style="padding:7px 10px;border:1px solid var(--border);border-radius:6px;font-size:13px;resize:vertical"
      ></textarea>
      <div :if={@form_error} class="form-error" style="color:var(--bad, #b91c1c);font-size:12px">{@form_error}</div>
      <div>
        <.button variant="primary" type="submit">Log activity</.button>
      </div>
    </form>
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

  defp activity_type(t) when t in @activity_types, do: String.to_existing_atom(t)
  defp activity_type(_), do: :note

  defp nz(nil), do: nil
  defp nz(""), do: nil
  defp nz(s) when is_binary(s), do: s

  defp stage_label(%{__stage__: %{label: label}}) when is_binary(label), do: label
  defp stage_label(%{__stage__: %{name: name}}) when is_binary(name), do: name
  defp stage_label(_), do: "—"

  defp opp_status_variant(:open), do: "info"
  defp opp_status_variant(:won), do: "ok"
  defp opp_status_variant(:lost), do: "bad"
  defp opp_status_variant(:on_hold), do: "warn"
  defp opp_status_variant(_), do: "mut"

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
