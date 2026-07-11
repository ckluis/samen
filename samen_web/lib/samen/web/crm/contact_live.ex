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

  ## A3 write side — edit + delete + the kit-form composer (AC-G1-1/2, MC-1/MC-2)

  "Edit contact" opens a `modal/1` hosting an `AshPhoenix.Form.for_update/3` over the
  PLANE-RESOLVED record — so on the operator plane the vaulted `full_name` arrives as
  `%Masked{}` and `full_name_field/1`/`form_field/1` render the read-only `••••`
  placeholder with NO `name` attribute (nothing can submit). On the tenant plane the
  name edits through nested first/last inputs that the composite `Samen.Type.FullName`
  casts, and the write routes through the vault write path (MC-2). An operator-plane
  plaintext write is REJECTED at the Ash write path by `Samen.Pii.WriteGuard` (MC-1) —
  the modal's plane gating is UX, not the enforcement. The log-activity composer is the
  A2 kit form now (`simple_form`/`form_field`, inline errors) — same tenant-plane-only
  posture as before. Delete carries the `delete_confirm/1` interlock and navigates back
  to the contacts list.
  """
  use Phoenix.LiveView

  import Samen.UI

  import Samen.Web.CRM.Live,
    only: [assign_mount: 2, crm_sidebar: 1, writable?: 1, full_name_field: 1]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.CRM.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    contact_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, contact_id: contact_id, active_tab: "overview", return_to: nil),
       org_id,
       contact_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    contact_id = Map.get(params, "id") || socket.assigns.contact_id
    tab = Map.get(params, "tab") || "overview"

    {:noreply,
     load(
       assign(socket, org_id: org_id, contact_id: contact_id, active_tab: tab, return_to: return_path(uri)),
       org_id,
       contact_id
     )}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  # Log-activity composer (ADR-011 §6.3), now the A2 kit form (AshPhoenix.Form-backed —
  # AC-G1-2 inline errors). Tenant plane only in the UI; the write goes through Ash so
  # OrgScope + the RoleAtLeast(:member) gate + SameOrgFk all apply — this LV adds NO
  # policy. `person_id`/`org_id`/`status`/`completed_at` are server-side facts merged
  # here, never client input.
  def handle_event("validate_activity", %{"activity" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.activity_form, params)
    {:noreply, assign(socket, activity_form: form)}
  end

  def handle_event("log_activity", %{"activity" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, contact_id: contact_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    params =
      Map.merge(params, %{
        "status" => "completed",
        "completed_at" => DateTime.utc_now() |> DateTime.truncate(:second),
        "person_id" => contact_id,
        "org_id" => org_id
      })

    case AshPhoenix.Form.submit(socket.assigns.activity_form, params: params) do
      {:ok, _activity} ->
        {:noreply,
         assign(socket,
           activity_form: activity_form(mount, scope),
           activities: Reads.activities_for_person(mount, scope, contact_id)
         )}

      {:error, form} ->
        {:noreply, assign(socket, activity_form: form)}
    end
  end

  # -- A3 edit/delete (the write side of the PII detail surface) ---------------

  def handle_event("edit_contact", _params, socket) do
    %{samen_mount: mount, org_id: org_id, contact: contact} = socket.assigns
    scope = Mount.scope(mount, org_id)
    {:noreply, assign(socket, show_edit: true, edit_form: edit_form(contact, scope))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, show_edit: false)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.edit_form, params)
    {:noreply, assign(socket, edit_form: form)}
  end

  # The edit submit. On the operator plane the masked `full_name` has NO input (the
  # form_field masked branch), so it never appears in `params`; a hand-crafted plaintext
  # write is REJECTED at the Ash write path by `Samen.Pii.WriteGuard` (MC-1) and renders
  # as a form error — the DB is unchanged. Tenant writes route through the vault (MC-2).
  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _person} ->
        socket = assign(socket, show_edit: false)
        {:noreply, load(socket, socket.assigns.org_id, socket.assigns.contact_id)}

      {:error, form} ->
        {:noreply, assign(socket, edit_form: form)}
    end
  end

  # FAIL-HONEST delete: navigate away ONLY when the destroy actually happened. The
  # kernel defines no cascade — a contact with linked activities is refused by the DB
  # (FK) and the refusal is SURFACED, never a silent no-op that navigates anyway.
  def handle_event("delete_contact", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.delete_contact(mount, scope, id) do
      :ok ->
        {:noreply, push_navigate(socket, to: contacts_path(mount, org_id))}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           delete_error: "Could not delete this contact — it still has linked records (activities)."
         )}
    end
  end

  @doc false
  def load(socket, nil, _contact_id) do
    tab = Map.get(socket.assigns, :active_tab, "overview")

    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      contact_id: nil,
      contact: nil,
      company_name: nil,
      activities: [],
      deals: [],
      active_tab: tab,
      show_edit: false,
      edit_form: nil,
      activity_form: nil,
      delete_error: nil
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

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      contact_id: contact_id,
      contact: contact,
      company_name: company_name,
      activities: activities,
      deals: deals,
      active_tab: tab,
      edit_form: contact && edit_form(contact, scope),
      activity_form: activity_form(mount, scope),
      delete_error: nil
    )
    |> assign_new(:show_edit, fn -> false end)
  end

  # The edit form is built over the PLANE-RESOLVED record (the same PiiResolution
  # chokepoint every read surface uses): on the tenant plane `full_name` is the clear
  # value, on the operator plane it is `%Masked{}` — which the form fields render as the
  # read-only •••• placeholder. This module never unwraps a %Masked{} and never calls
  # the vault.
  defp edit_form(contact, scope) do
    contact
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
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_contacts} return_to={@return_to} />
        </:sidebar>

        <.topbar title={contact_name(@contact) |> to_title()} crumbs={crumbs(@samen_mount, @org_id, contact_name(@contact) |> to_title())}>
          <:actions>
            <a href={contacts_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">
              <span class="i">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </span>
              Back to contacts
            </a>
            <.button :if={@contact != nil} phx-click="edit_contact" id="edit-contact">
              Edit contact
            </.button>
            <.delete_confirm
              :if={writable?(@samen_mount) and @contact != nil}
              id="delete-contact"
              message="Delete this contact? This cannot be undone."
              phx-click="delete_contact"
              phx-value-id={@contact && @contact.id}
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
                    <.empty_state
                      class="deals-empty"
                      icon="◇"
                      title="No deals yet."
                      body="Deals linked to this contact's company appear here — start one from the Pipeline."
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

            <%!-- The edit modal renders on BOTH planes (AC-G1-7): on the operator plane the
                 vaulted full_name arrives as %Masked{} and renders the read-only ••••
                 placeholder with NO name attribute — masking is by construction of the
                 value, never a plane branch here. Non-vaulted fields stay editable; the
                 kernel (OrgScope + Samen.Pii.WriteGuard) enforces the write rules. --%>
            <.modal :if={@show_edit and @edit_form != nil} id="edit-contact-modal" title="Edit contact" on_cancel="cancel_edit">
              <.simple_form :let={f} for={@edit_form} id="edit-contact-form" phx-change="validate_edit" phx-submit="save_edit">
                <%!-- display_name is deliberately NOT on this form: it is a non-vaulted
                     attribute that duplicates the person's name, and echoing it into an
                     editable input would leak the name on the operator plane (the A2
                     ContactEditLive fixture set this posture). --%>
                <.full_name_field field={f[:full_name]} label="Full name (🔒 PII)" />
                <.form_field field={f[:job_title]} label="Job title" />
                <:actions>
                  <.button variant="primary" type="submit">Save contact</.button>
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

  # The log-activity composer (rendered in the timeline's :composer slot; tenant plane
  # only) — the A2 kit form: AshPhoenix.Form-backed simple_form/form_field with inline
  # errors (AC-G1-2). Activity fields are non-PII (bounded enum + free-text metadata).
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
        <.form_field field={f[:subject]} label="Subject" placeholder="Subject (e.g. Check call — ETA confirmed)" />
        <.form_field field={f[:body]} label="Details" type="textarea" rows="2" placeholder="Details…" />
        <:actions>
          <.button variant="primary" type="submit">Log activity</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  # -- helpers (MASKING INVARIANT) -------------------------------------------

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "CRM", "Contacts", leaf]

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
