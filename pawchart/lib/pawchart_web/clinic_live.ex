defmodule PawChartWeb.ClinicLive do
  @moduledoc """
  The PawChart **Clinic** tenant surface (`/clinic`) — the vertical 20% (PP-4). A
  tenant-plane LiveView for clinic staff to manage their PATIENTS (the pet owners /
  clients) and PETS: a list + detail + create/edit flow over the EXISTING
  `PawChart.Clinic.Patient` / `PawChart.Clinic.Pet` resources. This is the vet analogue
  of `DriftwoodWeb.BrokerLive` (the freight vertical's tenant console): the resource
  SHAPE is vet-specific and legitimately host-local, but every MECHANISM — org-scope,
  per-plane masking, the current-org seam, the sidebar/kit — is inherited framework
  substrate. Thin wiring over `PawChartWeb.ClinicReads`.

  ## Why this exists (the dogfood finding it closes — PP-4)

  Before this, `PawChart.Clinic.Patient`/`Pet` (the vertical's NAMESAKE domain) had NO
  tenant-facing surface — the ONLY consumer was the operator's masked impersonation
  console, so a clinic's own staff had strictly LESS access to their patients than the
  platform operator. This surface gives the clinic its own workspace over its own data.

  ## Org-scope (the isolation boundary)

  Mounted under the router's `@current_org_labels` (authn + authorized_orgs +
  default_org_id), so `Samen.Web.CurrentOrg.resolve/3` is authn-gated + org-scoped by
  construction. Every read runs `PawChartWeb.ClinicReads` with a tenant scope, so
  `Samen.Policy.OrgScope` narrows to the clinic's own org — a clinic sees ONLY its own
  patients/pets, and a cross-org `?patient=` id is refused (`ClinicReads.get_owner/2`
  returns `:error`, the detail panel renders an honest "not found").

  ## Per-plane masking (this surface RENDERS vault-routed 🔒 fields)

  `Patient.full_name`/`emails`/`phones` (CorePerson, 🔒) and `Pet.microchip`
  (`pii_pet_microchip`, 🔒) render EXACTLY as `Samen.Api.PiiResolution` returns them —
  on the tenant plane CLEAR, on an operator-without-grant plane `%Samen.Masked{}` (••••).
  The render helpers NEVER unwrap a `%Samen.Masked{}`; a masked value passes straight
  through to `Phoenix.HTML.Safe` (renders `••••`), so no plaintext and no `vt_*` token can
  reach the DOM on a masked read. Proven by `clinic_masking_test.exs` (the three
  `Samen.MaskingCase` proofs) + sabotage patch 182.

  ## Honest first-run

  A fresh clinic with no patients/pets renders real empty states (never a stub/crash);
  a page with no resolvable org renders the framework `no_org_card`.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.CRM.Live, only: [writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1, switcher: 1]

  alias PawChartWeb.ClinicReads, as: Reads
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  # PP-4 (Batch 5b) — the `:host_nav_extra` mount-label DATA (`Samen.UI.host_nav_extra/1`,
  # wired at `@current_org_labels` in the router) so the "Clinic" group renders on EVERY
  # framework module sidebar (CRM/Billing/Support/…), not only this LiveView's own sidebar —
  # making the clinical record nav-reachable from anywhere in the tenant product. Called as
  # `apply(mod, fun, args ++ [org_id])`, so the arity here MUST be 1 (org_id appended).
  @doc false
  def clinic_nav_data(org_id) do
    %{
      label: "Clinic",
      items: [
        %{label: "Patients & Pets", href: "/clinic?org=#{org_id}"}
      ]
    }
  end

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id, params)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Map.get(params, "org") || socket.assigns.org_id
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id, params)}
  end

  @doc false
  def load(socket, nil, _params) do
    socket
    |> ensure_defaults()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      owners: [],
      pets: [],
      selected_owner: nil,
      selected_pets: []
    )
  end

  def load(socket, org_id, params) do
    scope = Mount.scope(socket.assigns.samen_mount, org_id)
    owners = Reads.owner_roster(scope)
    pets = Reads.pet_roster(scope)
    {selected_owner, selected_pets} = select_owner(scope, Map.get(params, "patient"))

    socket
    |> ensure_defaults()
    |> assign(
      no_org: false,
      org_id: org_id,
      owners: owners,
      pets: pets,
      selected_owner: selected_owner,
      selected_pets: selected_pets
    )
  end

  # An org-scoped fetch — a cross-org id is INVISIBLE under OrgScope, so it resolves to the
  # honest "not found" (nil selection), never another clinic's patient.
  defp select_owner(_scope, nil), do: {nil, []}
  defp select_owner(_scope, ""), do: {nil, []}

  defp select_owner(scope, owner_id) do
    case Reads.get_owner(scope, owner_id) do
      {:ok, owner} -> {owner, Reads.pets_for_owner(scope, owner_id)}
      :error -> {nil, []}
    end
  end

  defp ensure_defaults(socket) do
    socket
    |> default(:return_to, nil)
    |> default(:owner_modal, nil)
    |> default(:owner_error, nil)
    |> default(:owner_form, empty_owner_form())
    |> default(:pet_modal, nil)
    |> default(:pet_error, nil)
    |> default(:pet_form, empty_pet_form())
  end

  defp default(socket, key, value) do
    if Map.has_key?(socket.assigns, key), do: socket, else: assign(socket, key, value)
  end

  # ==========================================================================
  # Patient (owner) create/edit
  # ==========================================================================

  @impl true
  def handle_event("new_owner", _params, socket) do
    {:noreply, assign(socket, owner_modal: :new, owner_error: nil, owner_form: empty_owner_form())}
  end

  def handle_event("edit_owner", %{"id" => id}, socket) do
    scope = Mount.scope(socket.assigns.samen_mount, socket.assigns.org_id)

    case Reads.get_owner(scope, id) do
      {:ok, owner} ->
        {:noreply, assign(socket, owner_modal: {:edit, id}, owner_error: nil, owner_form: owner_form(owner))}

      :error ->
        {:noreply, assign(socket, owner_error: "Patient not found in this clinic.")}
    end
  end

  def handle_event("cancel_owner", _params, socket) do
    {:noreply, assign(socket, owner_modal: nil, owner_error: nil)}
  end

  def handle_event("save_owner", %{"owner" => params}, socket) do
    org_id = socket.assigns.org_id

    result =
      case socket.assigns.owner_modal do
        :new -> Reads.create_owner(org_id, params)
        {:edit, id} -> Reads.update_owner(org_id, id, params)
        _ -> {:error, :no_modal}
      end

    case result do
      {:ok, _owner} ->
        {:noreply,
         socket
         |> assign(owner_modal: nil, owner_error: nil)
         |> put_flash(:info, "Patient saved.")
         |> reload()}

      {:error, _reason} ->
        {:noreply, assign(socket, owner_error: "A first and last name are required.", owner_form: params)}
    end
  end

  # ==========================================================================
  # Pet create/edit
  # ==========================================================================

  def handle_event("new_pet", params, socket) do
    form = empty_pet_form() |> Map.put("owner_id", Map.get(params, "owner_id", ""))
    {:noreply, assign(socket, pet_modal: :new, pet_error: nil, pet_form: form)}
  end

  def handle_event("edit_pet", %{"id" => id}, socket) do
    scope = Mount.scope(socket.assigns.samen_mount, socket.assigns.org_id)

    case Enum.find(socket.assigns.pets ++ socket.assigns.selected_pets, &(&1.id == id)) do
      nil ->
        # Not in the already-loaded org-scoped roster ⇒ not this clinic's pet.
        {:noreply, assign(socket, pet_error: "Pet not found in this clinic.")}

      pet ->
        _ = scope
        {:noreply, assign(socket, pet_modal: {:edit, id}, pet_error: nil, pet_form: pet_form(pet))}
    end
  end

  def handle_event("cancel_pet", _params, socket) do
    {:noreply, assign(socket, pet_modal: nil, pet_error: nil)}
  end

  def handle_event("save_pet", %{"pet" => params}, socket) do
    org_id = socket.assigns.org_id

    result =
      case socket.assigns.pet_modal do
        :new -> Reads.create_pet(org_id, params)
        {:edit, id} -> Reads.update_pet(org_id, id, params)
        _ -> {:error, :no_modal}
      end

    case result do
      {:ok, _pet} ->
        {:noreply,
         socket
         |> assign(pet_modal: nil, pet_error: nil)
         |> put_flash(:info, "Pet saved.")
         |> reload()}

      {:error, _reason} ->
        {:noreply, assign(socket, pet_error: "A pet name is required, and the owner must be a patient of this clinic.", pet_form: params)}
    end
  end

  defp reload(socket) do
    patient = if socket.assigns.selected_owner, do: socket.assigns.selected_owner.id, else: nil
    load(socket, socket.assigns.org_id, %{"patient" => patient})
  end

  # ==========================================================================
  # Render
  # ==========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="clinic">
      <.app_shell>
        <:sidebar>
          <.clinic_sidebar mount={@samen_mount} org_id={@org_id} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Clinic" crumbs={[CurrentOrg.name(@samen_mount, @org_id), "Clinic", "Patients & Pets"]} />
        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Clinic org: {@org_id}</span>

          <div class="wrap" style="display:flex;flex-direction:column;gap:22px;padding:16px 20px">
            <p style="font-size:12px;color:var(--muted);line-height:1.5;margin:0">
              Your clinic's patients (the pet owners you bill and message) and their pets (the clinical
              record). Owner name / email / phone and a pet's microchip are 🔒 vaulted — your clinic reads
              them in the clear; the platform operator sees <b>••••</b>.
            </p>

            <%!-- Selected patient detail (via ?patient=<id>) --%>
            <section :if={@selected_owner} id="patient-detail" class="card" style="padding:16px 18px;display:flex;flex-direction:column;gap:12px">
              <div style="display:flex;align-items:center;justify-content:space-between;gap:10px">
                <h3 style="margin:0;font-size:14px;font-weight:650" class="owner-detail-name">{owner_name(@selected_owner)}</h3>
                <div style="display:flex;gap:8px">
                  <.button :if={writable?(@samen_mount)} phx-click="edit_owner" phx-value-id={@selected_owner.id}>Edit patient</.button>
                  <.link patch={"/clinic?org=#{@org_id}"} class="btn">Back to all</.link>
                </div>
              </div>
              <div style="display:flex;gap:24px;flex-wrap:wrap;font-size:13px">
                <div><span style="color:var(--muted)">Email</span><br /><span class="owner-detail-email">{owner_email(@selected_owner)}</span></div>
                <div><span style="color:var(--muted)">Phone</span><br /><span class="owner-detail-phone">{owner_phone(@selected_owner)}</span></div>
                <div><span style="color:var(--muted)">Marketing</span><br />{marketing_label(@selected_owner)}</div>
              </div>

              <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:6px">
                <h4 style="margin:0;font-size:12px;font-weight:600;color:var(--muted)">Pets</h4>
                <.button :if={writable?(@samen_mount)} phx-click="new_pet" phx-value-owner_id={@selected_owner.id}>New pet for this patient</.button>
              </div>
              <%= if @selected_pets == [] do %>
                <.empty_state class="owner-pets-empty" icon="🐾" title="No pets on file for this patient yet." />
              <% else %>
                <.data_table>
                  <:head>
                    <th style="width:28%">Pet</th>
                    <th style="width:18%">Species</th>
                    <th style="width:18%">Breed</th>
                    <th style="width:24%">Microchip 🔒</th>
                    <th style="width:12%"></th>
                  </:head>
                  <tr :for={p <- @selected_pets} class="owner-pet-row" id={"owner-pet-#{p.id}"}>
                    <td style="font-weight:500">{p.name}</td>
                    <td style="font-size:12px;color:var(--muted)">{p.species}</td>
                    <td style="font-size:12px;color:var(--muted)">{p.breed || "—"}</td>
                    <td class="pet-microchip mono" style="font-size:12px">{pet_microchip(p)}</td>
                    <td><.button :if={writable?(@samen_mount)} phx-click="edit_pet" phx-value-id={p.id}>Edit</.button></td>
                  </tr>
                </.data_table>
              <% end %>
            </section>

            <%!-- Patients (owners) --%>
            <section id="patients-list">
              <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:8px">
                <h3 style="margin:0;font-size:13px;font-weight:600">Patients (owners)</h3>
                <.button :if={writable?(@samen_mount)} variant="primary" phx-click="new_owner">New patient</.button>
              </div>
              <%= if @owners == [] do %>
                <.empty_state
                  class="patients-empty"
                  icon="👤"
                  title="No patients yet."
                  body="Add your first patient (a pet owner) to start building the clinical record."
                />
              <% else %>
                <.data_table>
                  <:head>
                    <th style="width:26%">Owner 🔒</th>
                    <th style="width:26%">Email 🔒</th>
                    <th style="width:20%">Phone 🔒</th>
                    <th style="width:14%">Marketing</th>
                    <th style="width:14%"></th>
                  </:head>
                  <tr :for={o <- @owners} class="patient-row" id={"patient-#{o.id}"}>
                    <td class="p-name" style="font-weight:500">
                      <.link patch={"/clinic?org=#{@org_id}&patient=#{o.id}"}>{owner_name(o)}</.link>
                    </td>
                    <td class="p-email" style="font-size:12px;color:var(--muted)">{owner_email(o)}</td>
                    <td class="p-phone" style="font-size:12px;color:var(--muted)">{owner_phone(o)}</td>
                    <td>{marketing_label(o)}</td>
                    <td>
                      <.button :if={writable?(@samen_mount)} phx-click="edit_owner" phx-value-id={o.id}>Edit</.button>
                    </td>
                  </tr>
                </.data_table>
              <% end %>
            </section>

            <%!-- Pets --%>
            <section id="pets-list">
              <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:8px">
                <h3 style="margin:0;font-size:13px;font-weight:600">Pets (clinical records)</h3>
                <.button :if={writable?(@samen_mount)} variant="primary" phx-click="new_pet">New pet</.button>
              </div>
              <%= if @pets == [] do %>
                <.empty_state
                  class="pets-empty"
                  icon="🐾"
                  title="No pets yet."
                  body="Add a pet and link it to its owner to open a clinical record."
                />
              <% else %>
                <.data_table>
                  <:head>
                    <th style="width:22%">Pet</th>
                    <th style="width:14%">Species</th>
                    <th style="width:14%">Breed</th>
                    <th style="width:20%">Microchip 🔒</th>
                    <th style="width:16%">Owner</th>
                    <th style="width:14%"></th>
                  </:head>
                  <tr :for={p <- @pets} class="pet-row" id={"pet-#{p.id}"}>
                    <td style="font-weight:500">{p.name}</td>
                    <td style="font-size:12px;color:var(--muted)">{p.species}</td>
                    <td style="font-size:12px;color:var(--muted)">{p.breed || "—"}</td>
                    <td class="pet-microchip mono" style="font-size:12px">{pet_microchip(p)}</td>
                    <td style="font-size:12px;color:var(--muted)">{owner_ref(@owners, p.owner_id)}</td>
                    <td><.button :if={writable?(@samen_mount)} phx-click="edit_pet" phx-value-id={p.id}>Edit</.button></td>
                  </tr>
                </.data_table>
              <% end %>
            </section>
          </div>
        <% end %>
      </.app_shell>

      <%!-- Patient (owner) modal — tenant plane only --%>
      <.modal :if={@owner_modal && writable?(@samen_mount)} id="owner-modal" title={owner_modal_title(@owner_modal)} on_cancel="cancel_owner">
        <form phx-submit="save_owner" id="owner-form" style="display:flex;flex-direction:column;gap:10px">
          <div :if={@owner_error} id="owner-error" style="color:#B42318;font-size:12px">{@owner_error}</div>
          <div style="display:flex;gap:8px">
            <label style="flex:1;display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
              First name (🔒 PII)
              <input type="text" name="owner[first]" id="owner-first" value={@owner_form["first"]} required />
            </label>
            <label style="flex:1;display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
              Last name (🔒 PII)
              <input type="text" name="owner[last]" id="owner-last" value={@owner_form["last"]} required />
            </label>
          </div>
          <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
            Email (🔒 PII)
            <input type="text" name="owner[email]" id="owner-email" value={@owner_form["email"]} />
          </label>
          <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
            Phone (🔒 PII)
            <input type="text" name="owner[phone]" id="owner-phone" value={@owner_form["phone"]} />
          </label>
          <label style="display:flex;align-items:center;gap:8px;font-size:12px;font-weight:600">
            <input type="checkbox" name="owner[marketing_opt_in]" id="owner-marketing" value="true" checked={@owner_form["marketing_opt_in"] == "true"} />
            Marketing opt-in (the clinic may message this owner)
          </label>
          <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:6px">
            <button type="button" class="btn" phx-click="cancel_owner">Cancel</button>
            <.button variant="primary" type="submit">Save patient</.button>
          </div>
        </form>
      </.modal>

      <%!-- Pet modal — tenant plane only --%>
      <.modal :if={@pet_modal && writable?(@samen_mount)} id="pet-modal" title={pet_modal_title(@pet_modal)} on_cancel="cancel_pet">
        <form phx-submit="save_pet" id="pet-form" style="display:flex;flex-direction:column;gap:10px">
          <div :if={@pet_error} id="pet-error" style="color:#B42318;font-size:12px">{@pet_error}</div>
          <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
            Name
            <input type="text" name="pet[name]" id="pet-name" value={@pet_form["name"]} required />
          </label>
          <div style="display:flex;gap:8px">
            <label style="flex:1;display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
              Species
              <input type="text" name="pet[species]" id="pet-species" value={@pet_form["species"]} />
            </label>
            <label style="flex:1;display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
              Breed
              <input type="text" name="pet[breed]" id="pet-breed" value={@pet_form["breed"]} />
            </label>
          </div>
          <div style="display:flex;gap:8px">
            <label style="flex:1;display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
              Weight (kg)
              <input type="text" name="pet[weight_kg]" id="pet-weight" value={@pet_form["weight_kg"]} />
            </label>
            <label style="flex:1;display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
              Temperament
              <select name="pet[temperament]" id="pet-temperament">
                <option :for={t <- ~w(docile anxious aggressive unknown)} value={t} selected={@pet_form["temperament"] == t}>{t}</option>
              </select>
            </label>
          </div>
          <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
            Microchip UID (🔒 PII)
            <input type="text" name="pet[microchip]" id="pet-microchip-input" value={@pet_form["microchip"]} />
          </label>
          <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
            Owner (patient)
            <select name="pet[owner_id]" id="pet-owner">
              <option value="">— unassigned —</option>
              <option :for={o <- @owners} value={o.id} selected={@pet_form["owner_id"] == o.id}>{owner_name(o)}</option>
            </select>
          </label>
          <div style="display:flex;gap:8px;justify-content:flex-end;margin-top:6px">
            <button type="button" class="btn" phx-click="cancel_pet">Cancel</button>
            <.button variant="primary" type="submit">Save pet</.button>
          </div>
        </form>
      </.modal>
    </div>
    """
  end

  # ==========================================================================
  # Sidebar (clinic-branded; the inherited module_nav + host_nav_extra so the
  # rest of the tenant product is reachable from the Clinic page and vice-versa).
  # ==========================================================================

  attr :mount, Mount, required: true
  attr :org_id, :string, default: nil
  attr :return_to, :string, default: nil

  defp clinic_sidebar(assigns) do
    ~H"""
    <.sidebar
      title={CurrentOrg.name(@mount, @org_id)}
      subtitle="Clinic"
      logo={Mount.label(@mount, :glyph, "V")}
      logo_style={Mount.label(@mount, :crm_logo_style, "background:linear-gradient(150deg,#0A6E9E,#1A8DC5)")}
    >
      <:switcher>
        <.switcher mount={@mount} org_id={@org_id} return_to={@return_to} compact />
      </:switcher>

      <.module_nav org_id={@org_id} active={:clinic}>
        <:extra><.host_nav_extra mount={@mount} org_id={@org_id} /></:extra>
      </.module_nav>

      <:footer>
        <div class="foot">
          <div class="av" style="background:#D6E9DF;color:#1E7A45">{Mount.label(@mount, :user_initials, "C")}</div>
          <div class="m">
            <b>{Mount.label(@mount, :user_name, "Clinic Staff")}</b><span>{Mount.label(@mount, :user_role, "veterinarian")}</span>
          </div>
        </div>
      </:footer>
    </.sidebar>
    """
  end

  # ==========================================================================
  # Masking-safe presentation helpers (NEVER unwrap a %Samen.Masked{}: a masked
  # value passes straight through to Phoenix.HTML.Safe, rendering ••••).
  # ==========================================================================

  # full_name resolves to a %Masked{} (operator), a JSON string / map (tenant clear),
  # or nil. A %Masked{} is returned UNTOUCHED so it renders ••••.
  @doc false
  def owner_name(%{full_name: %Samen.Masked{} = m}), do: m
  def owner_name(%{full_name: fname}), do: format_name(fname)
  def owner_name(_), do: "—"

  defp format_name(%{"first" => f, "last" => l}), do: join_name(f, l)
  defp format_name(%{first: f, last: l}), do: join_name(f, l)

  defp format_name(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"first" => f, "last" => l}} -> join_name(f, l)
      _ -> json
    end
  end

  defp format_name(_), do: "—"

  defp join_name(f, l), do: String.trim("#{f} #{l}")

  # emails/phones resolve to a list (tenant clear), a %Masked{} (operator), or an
  # %Ash.ForbiddenField{}. A %Masked{} renders ••••; a list is joined; anything else "—".
  @doc false
  def owner_email(%{emails: emails}), do: first_of(emails)
  def owner_email(_), do: "—"

  @doc false
  def owner_phone(%{phones: phones}), do: first_of(phones)
  def owner_phone(_), do: "—"

  # emails/phones resolve on the tenant plane to a JSON string (`["a@b.test"]`) or a list;
  # on the operator plane to a %Samen.Masked{} (passed through untouched → ••••).
  defp first_of(%Samen.Masked{} = m), do: m
  defp first_of(list) when is_list(list), do: first_entry(list)

  defp first_of(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> first_entry(list)
      _ -> "—"
    end
  end

  defp first_of(_), do: "—"

  defp first_entry([%{"address" => a} | _]) when is_binary(a), do: a
  defp first_entry([%{"number" => n} | _]) when is_binary(n), do: n
  defp first_entry([first | _]) when is_binary(first), do: first
  defp first_entry(_), do: "—"

  # microchip resolves to a %Masked{} (operator) or a plaintext string (tenant clear).
  @doc false
  def pet_microchip(%{microchip: %Samen.Masked{} = m}), do: m
  def pet_microchip(%{microchip: v}) when is_binary(v) and v != "", do: v
  def pet_microchip(_), do: "—"

  defp marketing_label(%{marketing_opt_in: true}), do: "Opted in"
  defp marketing_label(_), do: "—"

  defp owner_ref(owners, owner_id) when is_binary(owner_id) do
    case Enum.find(owners, &(&1.id == owner_id)) do
      nil -> "—"
      owner -> owner_name(owner)
    end
  end

  defp owner_ref(_owners, _owner_id), do: "—"

  defp owner_modal_title(:new), do: "New patient"
  defp owner_modal_title({:edit, _}), do: "Edit patient"
  defp owner_modal_title(_), do: "Patient"

  defp pet_modal_title(:new), do: "New pet"
  defp pet_modal_title({:edit, _}), do: "Edit pet"
  defp pet_modal_title(_), do: "Pet"

  # ==========================================================================
  # Form prefill (from a resolved, CLEAR tenant-plane record). A %Samen.Masked{}
  # value prefills as "" (an operator never authors here — writable? is tenant-only).
  # ==========================================================================

  defp empty_owner_form,
    do: %{"first" => "", "last" => "", "email" => "", "phone" => "", "marketing_opt_in" => "false"}

  defp owner_form(owner) do
    {first, last} = name_parts(Map.get(owner, :full_name))

    %{
      "first" => first,
      "last" => last,
      "email" => clear_first(Map.get(owner, :emails)),
      "phone" => clear_first(Map.get(owner, :phones)),
      "marketing_opt_in" => if(Map.get(owner, :marketing_opt_in) == true, do: "true", else: "false")
    }
  end

  defp name_parts(%Samen.Masked{}), do: {"", ""}
  defp name_parts(%{"first" => f, "last" => l}), do: {to_string(f), to_string(l)}
  defp name_parts(%{first: f, last: l}), do: {to_string(f), to_string(l)}

  defp name_parts(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"first" => f, "last" => l}} -> {to_string(f), to_string(l)}
      _ -> {"", ""}
    end
  end

  defp name_parts(_), do: {"", ""}

  # Prefill the single email/phone input from the CLEAR (tenant-plane) resolved value —
  # a JSON string or a list. A %Samen.Masked{} prefills "" (an operator never edits here).
  defp clear_first(%Samen.Masked{}), do: ""

  defp clear_first(list) when is_list(list) do
    case first_entry(list) do
      "—" -> ""
      entry -> entry
    end
  end

  defp clear_first(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> clear_first(list)
      _ -> ""
    end
  end

  defp clear_first(_), do: ""

  defp empty_pet_form,
    do: %{"name" => "", "species" => "", "breed" => "", "weight_kg" => "", "temperament" => "unknown", "microchip" => "", "owner_id" => ""}

  defp pet_form(pet) do
    %{
      "name" => to_string(Map.get(pet, :name) || ""),
      "species" => to_string(Map.get(pet, :species) || ""),
      "breed" => to_string(Map.get(pet, :breed) || ""),
      "weight_kg" => weight_string(Map.get(pet, :weight_kg)),
      "temperament" => to_string(Map.get(pet, :temperament) || "unknown"),
      "microchip" => microchip_string(Map.get(pet, :microchip)),
      "owner_id" => to_string(Map.get(pet, :owner_id) || "")
    }
  end

  # A masked microchip (operator plane) prefills empty — an operator never edits here.
  defp microchip_string(%Samen.Masked{}), do: ""
  defp microchip_string(v) when is_binary(v), do: v
  defp microchip_string(_), do: ""

  defp weight_string(nil), do: ""
  defp weight_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp weight_string(v), do: to_string(v)
end
