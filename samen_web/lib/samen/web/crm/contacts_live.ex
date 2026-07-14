defmodule Samen.Web.CRM.ContactsLive do
  @moduledoc """
  Framework CRM / Contacts page — 🔒 PII: person name, email, phone (ADR-009).

  Reads the host's `<namespace>.Person` via `Samen.Web.CRM.Reads.contacts/2`. `full_name`,
  `emails`, `phones` are vault-routed PII resolved through `Samen.Api.PiiResolution`:

    * TENANT plane — the org reads its OWN contacts in CLEAR.
    * OPERATOR / impersonation plane — the SAME fields render `%Masked{}` (→ ••••). The
      resolver is the SINGLE vault chokepoint; this page introduces NO plaintext bypass.

  The page renders whatever value the resolver returns. A `%Samen.Masked{}` renders `••••`
  via `Phoenix.HTML.Safe`. This LiveView NEVER calls `Samen.Vault.reveal/3`, NEVER unwraps a
  vault token out of a `%Masked{}`, and has NO "show plaintext" branch.

  ## A2 retrofit — the contract smoke proof

  This is the FIRST framework list on the `ListLive` + `list_view/1` contract (ADR-016
  §2/§3): `use Samen.Web.ListLive` + a `%Page{}`-returning bounded read
  (`Reads.contacts_page/3`) buys sort/filter/keyset-pagination/empty-state as KIT
  DEFAULTS — this view carries NO `handle_event/3` for list ergonomics and NO unbounded
  read. Both verticals inherit the retrofit through the `Samen.Web.Router.samen_crm`
  mount at 0 vertical lines.

  ## A3 write side — create + delete (AC-G1-1/2, MC-1/MC-2)

  "New contact" opens a `modal/1` hosting an `AshPhoenix.Form`-backed `simple_form/1`
  create; each row carries a `delete_confirm/1`. Write AFFORDANCES are offered on the
  tenant plane only (`Samen.Web.CRM.Live.writable?/1` — the composer posture); the
  ENFORCEMENT is the kernel's: OrgScope on every write and `Samen.Pii.WriteGuard`
  rejecting an operator-plane plaintext write to the vaulted `full_name` at the Ash
  write path (MC-1). The tenant's `full_name` submits through the vault write path —
  the same `Samen.Vault.Change` chokepoint as seeds (MC-2); this LiveView never sees
  a token and never unwraps a `%Masked{}`.
  """
  use Phoenix.LiveView

  import Samen.UI

  import Samen.Web.CRM.Live,
    only: [assign_mount: 2, crm_sidebar: 1, writable?: 1, full_name_field: 1]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]
  import Samen.Web.FirstRun, only: [first_run_card: 1]

  alias Samen.Web.CRM.Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.FirstRun
  alias Samen.Web.Mount
  alias Samen.Web.SampleData

  use Samen.Web.ListLive,
    resource: Person,
    reads: &Samen.Web.CRM.Reads.contacts_page/3,
    sortable: [:display_name, :job_title],
    filter_fields: [:display_name, :job_title],
    default_sort: {:display_name, :asc}

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
    |> default_return_to()
    |> assign(no_org: no_org?(socket, nil), org_id: nil, company_names: %{})
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(show_new: false, new_form: nil, first_run: false)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign_new(:sample_error, fn -> nil end)
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> default_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      company_names: company_name_map(mount, scope),
      # AC-G5-2: the tenant first-run checklist — zero rows across the CRM core
      # resources. FALSE by construction on the operator plane (FirstRun).
      first_run: FirstRun.first_run?(mount, org_id)
    )
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:delete_error, fn -> nil end)
    |> assign_new(:sample_error, fn -> nil end)
    |> assign(new_form: new_contact_form(mount, scope))
    |> init_list(mount, scope)
  end

  # -- A3 CRUD events (list events belong to the ListLive hook) -----------------

  @impl true
  def handle_event("new_contact", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)
    {:noreply, assign(socket, show_new: true, new_form: new_contact_form(mount, scope))}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # The create submit. `org_id` is the server-side fact, never client input. The vaulted
  # `full_name` arrives as the nested `%{"first" => _, "last" => _}` map the composite
  # type casts; on the tenant plane the write routes through the vault (MC-2), on the
  # operator plane `Samen.Pii.WriteGuard` REJECTS it at the write path (MC-1) and the
  # error renders inline — this LiveView adds no policy of its own.
  def handle_event("save_new", %{"form" => params}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    # WS-B / G12 (design §4.2): capture the first-run state BEFORE the create (the org is
    # non-empty afterwards) so the framework choke point can emit the empty→non-empty
    # `first_run.completed` alongside `record.created`. Best-effort — never affects the write.
    was_first_run? = FirstRun.first_run?(mount, org_id)

    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, person} ->
        FirstRun.emit_record_created(mount, org_id, was_first_run?,
          resource: Person,
          entity_ref: person.id
        )

        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  # AC-G5-3: the in-app sample-data offer. ENFORCEMENT lives in SampleData.load/2
  # (tenant plane only · disabled-in-prod-unless-flagged · idempotent · audited ·
  # vault write path) — this handler only relays and re-reads. A refusal is
  # SURFACED (fail-honest), never swallowed.
  def handle_event("load_sample_data", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case SampleData.load(mount, org_id) do
      {:ok, _} ->
        {:noreply, load(assign(socket, sample_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply, assign(socket, sample_error: "Sample data is not available here.")}
    end
  end

  # FAIL-HONEST delete: the kernel defines no cascade — a contact with linked
  # activities is refused by the DB (FK) and the refusal is SURFACED on the page.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    case Reads.delete_contact(mount, scope, id) do
      :ok ->
        {:noreply, load(assign(socket, delete_error: nil), org_id)}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           delete_error: "Could not delete this contact — it still has linked records (activities)."
         )}
    end
  end

  defp new_contact_form(mount, scope) do
    Mount.resource(mount, Person)
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  defp no_org?(socket, org_id), do: CurrentOrg.no_org?(socket.assigns[:samen_mount], org_id)

  defp default_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to),
      do: socket,
      else: assign(socket, return_to: nil)
  end

  defp company_name_map(mount, scope) do
    Reads.companies(mount, scope) |> Map.new(fn c -> {c.id, c.name} end)
  rescue
    _ -> %{}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="crm-contacts">
      <.app_shell>
        <:sidebar>
          <.crm_sidebar mount={@samen_mount} org_id={@org_id} active={:crm_contacts} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Contacts" crumbs={crumbs(@samen_mount, @org_id, "Contacts")}>
          <:actions>
            <.button :if={writable?(@samen_mount) and not @no_org} variant="primary" phx-click="new_contact" id="new-contact">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New contact
            </.button>
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

          <div :if={@sample_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="sample-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@sample_error}
            </div>
          </div>

          <div :if={@first_run and writable?(@samen_mount)} class="wrap" style="margin-bottom:0">
            <.first_run_card
              create_event="new_contact"
              create_label="Add your first contact"
              sample?={SampleData.offer?(@samen_mount)}
            />
          </div>

          <div class="wrap">
            <div id="contacts-panel">
              <div class="gtitle">
                <h3>Contacts</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· name / email / phone via PiiResolution · {plane_note(@samen_mount)}</span>
              </div>
              <.list_view
                id="contacts"
                page={@page}
                state={@list_state}
                row_class="contact-row"
                filter_placeholder="Filter contacts…"
                empty_text="No contacts yet."
                empty_icon="◉"
                empty_body="Contacts are your people book — names, emails, and phones, all vault-protected."
              >
                <:empty_actions :if={writable?(@samen_mount)}>
                  <.button variant="primary" phx-click="new_contact" id="empty-new-contact">New contact</.button>
                </:empty_actions>
                <:empty_sample :if={writable?(@samen_mount) and SampleData.offer?(@samen_mount)}>
                  <.button phx-click="load_sample_data" id="load-sample-data">Load sample data</.button>
                </:empty_sample>
                <:head>
                  <.sort_header field={:display_name} label="Name" sort={@list_state.sort} width="24%" />
                  <th scope="col" style="width:20%">Email</th>
                  <th scope="col" style="width:14%">Phone</th>
                  <th scope="col" style="width:20%">Company</th>
                  <.sort_header field={:job_title} label="Title" sort={@list_state.sort} width="14%" />
                  <th :if={writable?(@samen_mount)} scope="col" style="width:8%"><span class="sr-only">Actions</span></th>
                </:head>
                <:row :let={p}>
                  <td class="p-name">
                    <a href={contact_path(@samen_mount, @org_id, p.id)} style="display:flex;align-items:center;gap:8px;text-decoration:none">
                      <div class="av" style="width:28px;height:28px;border-radius:50%;background:#DDE7F5;color:#3B4CCA;font-size:10px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0">
                        {contact_initials(p.full_name, p.display_name)}
                      </div>
                      <span class="p-full-name" style="font-weight:500;color:#3B4CCA">
                        {render_full_name(p.full_name, p.display_name)}
                      </span>
                    </a>
                  </td>
                  <td class="p-email" style="font-size:12px;color:var(--muted)">
                    {render_email(p.emails)}
                  </td>
                  <td class="p-phone" style="font-size:12px;color:var(--muted)">
                    {render_phone(p.phones)}
                  </td>
                  <td class="p-company" style="color:var(--muted)">{(p.company_id && Map.get(@company_names, p.company_id)) || "—"}</td>
                  <td class="p-title" style="color:var(--muted);font-size:12px">{p.job_title || "—"}</td>
                  <td :if={writable?(@samen_mount)} class="p-actions">
                    <.delete_confirm phx-click="delete" phx-value-id={p.id} />
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-contact-modal" title="New contact" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-contact-form" phx-change="validate_new" phx-submit="save_new">
              <.full_name_field field={f[:full_name]} label="Full name (🔒 PII)" />
              <.form_field field={f[:display_name]} label="Display name" />
              <.form_field field={f[:job_title]} label="Job title" />
              <.form_field
                field={f[:company_id]}
                label="Company"
                type="select"
                prompt="No company"
                options={Enum.map(@company_names, fn {id, name} -> {name, id} end)}
              />
              <:actions>
                <.button variant="primary" type="submit">Save contact</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers (MASKING INVARIANT) -------------------------------------------
  #
  # These helpers render ALREADY-RESOLVED values from PiiResolution. They NEVER unwrap a
  # %Masked{} or call the vault. A %Masked{} is returned AS-IS so it renders •••• through
  # Phoenix.HTML.Safe. Only a plaintext string is reshaped.

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "CRM", leaf]

  defp contact_path(mount, org_id, id),
    do: "#{Mount.label(mount, :crm_path, "/crm")}/contacts/#{id}?org=#{org_id}"

  defp plane_note(%Mount{plane: %{kind: :operator}}), do: "operator plane · masked"
  defp plane_note(_), do: "your org in the clear"

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

  defp contact_initials(%Samen.Masked{}, _display_name), do: "··"

  defp contact_initials(name, _display_name) when is_binary(name) do
    label =
      case Jason.decode(name) do
        {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
        _ -> name
      end

    initials(label)
  end

  defp contact_initials(nil, display_name) when is_binary(display_name), do: initials(display_name)
  defp contact_initials(_, _), do: "??"

  defp initials(label) do
    label
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.slice(&1, 0, 1))
    |> String.upcase()
  end

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
