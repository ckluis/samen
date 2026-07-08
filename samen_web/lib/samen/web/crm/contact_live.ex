defmodule Samen.Web.CRM.ContactLive do
  @moduledoc """
  Framework CRM / Contact detail (`/crm/contacts/:id`) — 🔒 PII surface (ADR-011 §4.1).

  A tabbed detail page (Overview · Activity · Deals) over the host's `<ns>.Person`, read via
  `Samen.Web.CRM.Reads.get_contact/3`. `full_name`/`emails`/`phones` are vault-routed PII
  resolved through `Samen.Api.PiiResolution`:

    * TENANT plane — the org reads its OWN contact in CLEAR (view + email its own people).
    * OPERATOR / impersonation plane — the SAME fields render `%Masked{}` (→ ••••), and the
      log-activity composer is HIDDEN (an operator does not author into a tenant's timeline).

  ## MASKING INVARIANT

  This LiveView NEVER calls `Samen.Vault.reveal/3`, NEVER unwraps a `%Masked{}`, and has NO
  "show plaintext" branch. It renders whatever the resolver returned — a `%Masked{}` renders
  `••••` via `Phoenix.HTML.Safe`. The masking helpers are copied in posture from
  `Samen.Web.CRM.ContactsLive` (render `%Masked{}` as-is; only reshape a plaintext string).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [assign_mount: 2, crm_sidebar: 1]

  alias Samen.Web.CRM.Reads
  alias Samen.Web.Mount

  @activity_types ~w(note call email meeting task)

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = Map.get(params, "org")
    contact_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, contact_id: contact_id, active_tab: "overview", form_error: nil),
       org_id,
       contact_id
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    contact_id = Map.get(params, "id") || socket.assigns.contact_id
    tab = Map.get(params, "tab") || "overview"

    {:noreply,
     load(assign(socket, org_id: org_id, contact_id: contact_id, active_tab: tab), org_id, contact_id)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  # Log-activity composer (ADR-011 §6.3). Tenant plane only — the composer is not rendered on
  # the operator plane, so this handler only runs there. Org-scoped write through Ash; the
  # kernel enforces OrgScope + member gate + SameOrgFk. This LV adds no policy.
  def handle_event("log_activity", %{"activity" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, contact_id: contact_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    attrs = %{
      type: activity_type(params["type"]),
      subject: nz(params["subject"]),
      body: nz(params["body"]),
      status: :completed,
      completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      person_id: contact_id,
      org_id: org_id
    }

    case Reads.create_activity(mount, scope, attrs) do
      {:ok, _activity} ->
        {:noreply,
         assign(socket,
           form_error: nil,
           activities: Reads.activities_for_person(mount, scope, contact_id)
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, form_error: "Could not log the activity. Check the fields and try again.")}
    end
  end

  @doc false
  def load(socket, nil, _contact_id) do
    tab = Map.get(socket.assigns, :active_tab, "overview")

    assign(socket,
      no_org: true,
      org_id: nil,
      contact_id: nil,
      contact: nil,
      company_name: nil,
      activities: [],
      deals: [],
      active_tab: tab,
      form_error: nil
    )
  end

  def load(socket, org_id, contact_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    contact =
      if contact_id do
        case Reads.get_contact(mount, scope, contact_id) do
          {:ok, person} -> person
          :error -> nil
        end
      end

    {activities, deals, company_name} =
      if contact do
        acts = Reads.activities_for_person(mount, scope, contact_id)
        d = if contact.company_id, do: Reads.opportunities_for_company(mount, scope, contact.company_id), else: []
        name = contact.company_id && company_name(mount, scope, contact.company_id)
        {acts, d, name}
      else
        {[], [], nil}
      end

    tab = Map.get(socket.assigns, :active_tab, "overview")

    assign(socket,
      no_org: false,
      org_id: org_id,
      contact_id: contact_id,
      contact: contact,
      company_name: company_name,
      activities: activities,
      deals: deals,
      active_tab: tab,
      form_error: Map.get(socket.assigns, :form_error)
    )
  end

  defp company_name(mount, scope, company_id) do
    case Reads.get_company(mount, scope, company_id) do
      {:ok, company} -> company.name
      :error -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-contact">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_contacts} />
        </:sidebar>

        <.topbar title={contact_name(@contact) |> to_title()} crumbs={crumbs(@samen_mount, contact_name(@contact) |> to_title())}>
          <:actions>
            <a href={contacts_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">
              <span class="i">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </span>
              Back to contacts
            </a>
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

          <%= if @contact == nil do %>
            <div class="wrap">
              <div class="card" style="padding:22px 20px;color:var(--muted)">Contact not found.</div>
            </div>
          <% else %>
            <div class="wrap" style="margin-bottom:0">
              <div class="card" id="contact-header" style="padding:18px 20px;display:flex;align-items:center;gap:14px;flex-wrap:wrap">
                <div class="av" style="width:46px;height:46px;border-radius:50%;background:#DDE7F5;color:#3B4CCA;font-size:15px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                  {contact_initials(@contact)}
                </div>
                <div style="flex:1;min-width:0">
                  <h1 class="c-full-name" style="font-weight:600;font-size:18px;color:#2a2b35;margin:0 0 2px">
                    {render_full_name(@contact.full_name, @contact.display_name)}
                  </h1>
                  <div style="font-size:12px;color:var(--muted);display:flex;gap:10px;flex-wrap:wrap;align-items:center">
                    <span class="c-title">{@contact.job_title || "—"}</span>
                    <span :if={@company_name}>· {@company_name}</span>
                    <.lifecycle_pill stage={lifecycle_stage(@contact)} />
                    <.social_links custom={@contact.custom} />
                  </div>
                </div>
                <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
                  <span class="c-email" style="font-size:12px;color:var(--muted)">{render_email(@contact.emails)}</span>
                  <span class="c-phone" style="font-size:12px;color:var(--muted)">{render_phone(@contact.phones)}</span>
                </div>
              </div>
              <div style="padding:6px 20px 0;font-size:11px;color:var(--muted)">· name / email / phone via PiiResolution · {plane_note(@samen_mount)}</div>
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
                    <div class="card" style="padding:22px 20px;color:var(--muted)">No deals linked to this contact's company yet.</div>
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
                    <div class="gtitle" style="margin-bottom:16px"><h3>Contact details</h3></div>
                    <table style="width:100%;font-size:13px;border-collapse:collapse">
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted);width:160px">Name (🔒 PII)</td>
                        <td style="padding:10px 0" class="ov-name">{render_full_name(@contact.full_name, @contact.display_name)}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Email (🔒 PII)</td>
                        <td style="padding:10px 0" class="ov-email">{render_email(@contact.emails)}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Phone (🔒 PII)</td>
                        <td style="padding:10px 0" class="ov-phone">{render_phone(@contact.phones)}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Title</td>
                        <td style="padding:10px 0">{@contact.job_title || "—"}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Company</td>
                        <td style="padding:10px 0">{@company_name || "—"}</td>
                      </tr>
                      <tr style="border-bottom:1px solid var(--border)">
                        <td style="padding:10px 0;color:var(--muted)">Lifecycle stage</td>
                        <td style="padding:10px 0"><.lifecycle_pill stage={lifecycle_stage(@contact)} /> {if lifecycle_stage(@contact) == nil, do: "—", else: ""}</td>
                      </tr>
                      <tr>
                        <td style="padding:10px 0;color:var(--muted)">Social</td>
                        <td style="padding:10px 0"><.social_links custom={@contact.custom} /></td>
                      </tr>
                    </table>
                  </div>
                </div>
            <% end %>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # The log-activity composer form (rendered in the timeline's :composer slot; tenant plane only).
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
          placeholder="Subject (e.g. Check call — ETA confirmed)"
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

  # -- helpers (MASKING INVARIANT) -------------------------------------------

  defp crumbs(mount, leaf), do: [Mount.label(mount, :crumb_root, "Workspace"), "CRM", "Contacts", leaf]

  # The composer is tenant-plane only (ADR-011 §6.3): an operator never authors into a
  # tenant's timeline. Hidden on the operator plane; the plane note already signals it.
  defp composer?(%Mount{plane: %{kind: :operator}}), do: false
  defp composer?(_), do: true

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  defp plane_note(_), do: "your org in the clear"

  defp contacts_path(mount, org_id), do: "#{crm_path(mount)}/contacts?org=#{org_id}"
  defp crm_path(mount), do: Mount.label(mount, :crm_path, "/crm")

  defp lifecycle_stage(%{custom: custom}) when is_map(custom), do: Map.get(custom, "lifecycle_stage")
  defp lifecycle_stage(_), do: nil

  defp contact_name(nil), do: "Contact"
  defp contact_name(%{full_name: full_name, display_name: display_name}),
    do: render_full_name(full_name, display_name)

  # The topbar title is a plain string; a masked name collapses to a neutral label there
  # (the header H1 carries the real masked sentinel).
  defp to_title(%Samen.Masked{}), do: "Contact"
  defp to_title(str) when is_binary(str), do: str
  defp to_title(_), do: "Contact"

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

  # PII renderers — copied in posture from ContactsLive (render %Masked{} as-is).

  defp contact_initials(%{full_name: %Samen.Masked{}}), do: "··"

  defp contact_initials(%{full_name: name, display_name: display_name}),
    do: contact_initials_of(name, display_name)

  defp contact_initials_of(name, _display_name) when is_binary(name) do
    label =
      case Jason.decode(name) do
        {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
        _ -> name
      end

    initials(label)
  end

  defp contact_initials_of(nil, display_name) when is_binary(display_name), do: initials(display_name)
  defp contact_initials_of(_, _), do: "??"

  defp initials(label) do
    label
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

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

  defp render_phone(%Samen.Masked{} = masked), do: masked
  defp render_phone(%Samen.Type.Phones{entries: entries}), do: render_phone(entries)

  defp render_phone(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_phone(list)
      _ -> "—"
    end
  end

  defp render_phone(phones) when is_list(phones) do
    case List.first(phones) do
      %{"number" => num} -> num
      %{number: num} -> num
      _ -> "—"
    end
  end

  defp render_phone(_), do: "—"
end
