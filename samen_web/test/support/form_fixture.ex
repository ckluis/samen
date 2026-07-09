defmodule Samen.WebTest.FormFixture.CompanyFormLive do
  @moduledoc """
  The A2 form/modal/empty-state fixture LiveView — a minimal list-with-CRUD page over
  the test host's `Crm.Company` (non-PII by design: `name` is `allow_nil?: false`, so
  the inline-validation-error path is provable without touching a vaulted field).
  Exercises the FULL A2 form-primitive loop the way an A3 vertical will:

    * `empty_state/1` at zero rows, with an `:actions` CTA + a `:sample` affordance
      (both wired to real events — the AC-G5-1 component proof).
    * `modal/1` hosting an `AshPhoenix.Form`-backed `simple_form/1` create
      (open via the "New …" button — the AC-G1-1 shape).
    * `validate`/`save` through `AshPhoenix.Form` — an invalid submit renders inline
      `form_field/1` errors and persists NOTHING; a valid submit persists + refreshes
      the (bounded) list + closes the modal (AC-G1-2).
    * `delete_confirm/1` per row + a `delete` event destroying through Ash.

  Reads stay BOUNDED (`Samen.Web.Reads.page!/3`) — no unbounded `.read!()` sneaks in
  through the fixture.
  """
  use Phoenix.LiveView

  import Samen.UI

  alias Samen.Web.ListState
  alias Samen.Web.Mount

  @doc false
  def load(socket, org_id) do
    socket
    |> assign(
      org_id: org_id,
      show_modal: false,
      saved: nil,
      deleted: nil,
      sample_requested: false
    )
    |> assign_companies()
    |> assign_new_form()
  end

  @impl true
  def handle_event("open_modal", _params, socket) do
    {:noreply, socket |> assign_new_form() |> assign(show_modal: true)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, show_modal: false)}
  end

  def handle_event("load_sample", _params, socket) do
    # A2 proves the AFFORDANCE wires an event; the guarded `SampleData.load/2` is A5.
    {:noreply, assign(socket, sample_requested: true)}
  end

  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form, with_org(params, socket))
    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: with_org(params, socket)) do
      {:ok, company} ->
        {:noreply,
         socket
         |> assign(saved: company, show_modal: false)
         |> assign_companies()
         |> assign_new_form()}

      {:error, form} ->
        # Invalid submit: keep the modal open, render inline errors (AC-G1-2).
        {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    Mount.resource(mount, Company)
    |> Ash.get!(id, scope: scope)
    |> Ash.destroy!(scope: scope)

    {:noreply, socket |> assign(deleted: id) |> assign_companies()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="company-form-fixture">
      <.topbar title="Companies">
        <:actions>
          <.button variant="primary" phx-click="open_modal" id="new-company">New company</.button>
        </:actions>
      </.topbar>

      <%= if @companies == [] do %>
        <.empty_state
          title="No companies yet"
          body="Create your first company to get started."
          icon="🏢"
        >
          <:actions>
            <.button variant="primary" phx-click="open_modal" id="empty-new-company">New company</.button>
          </:actions>
          <:sample>
            <button type="button" id="load-sample" phx-click="load_sample">Load sample data</button>
          </:sample>
        </.empty_state>
      <% else %>
        <.data_table>
          <:head>
            <th scope="col">Name</th>
            <th scope="col">Industry</th>
            <th scope="col"><span class="sr-only">Actions</span></th>
          </:head>
          <tr :for={c <- @companies} id={"company-#{c.id}"}>
            <td class="c-name">{c.name}</td>
            <td class="c-industry">{c.industry || "—"}</td>
            <td>
              <.delete_confirm phx-click="delete" phx-value-id={c.id} />
            </td>
          </tr>
        </.data_table>
      <% end %>

      <.modal :if={@show_modal} id="company-modal" title="New company" on_cancel="close_modal">
        <.simple_form :let={f} for={@form} id="company-form" phx-change="validate" phx-submit="save">
          <.form_field field={f[:name]} label="Name" />
          <.form_field field={f[:industry]} label="Industry" type="select" prompt="Pick one" options={["Freight", "Veterinary"]} />
          <.form_field field={f[:notes]} label="Notes" type="textarea" />
          <:actions>
            <.button variant="primary" type="submit">Save</.button>
            <.button type="button" phx-click="close_modal">Cancel</.button>
          </:actions>
        </.simple_form>
      </.modal>
    </div>
    """
  end

  # -- internals ---------------------------------------------------------------

  # The bounded list read (Samen.Web.Reads — limit ALWAYS applied). Company is non-PII.
  defp assign_companies(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    page =
      Mount.resource(mount, Company)
      |> Samen.Web.Reads.page!(%ListState{sort: {:name, :asc}, page_size: 20}, scope: scope)

    assign(socket, companies: page.items)
  end

  defp assign_new_form(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    form =
      Mount.resource(mount, Company)
      |> AshPhoenix.Form.for_create(:create, scope: scope)
      |> to_form()

    assign(socket, form: form)
  end

  # `org_id` is the fixture's server-side fact, never client input.
  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)
end

defmodule Samen.WebTest.FormFixture.ContactEditLive do
  @moduledoc """
  The A2 PER-PLANE FORM-MASKING fixture — an edit form over the test host's
  `Crm.Person` (🔒 `full_name`/`emails`/`phones` are vault-routed PII). The SAME
  LiveView, loaded on the two planes, proves the write-form masking rule
  (WS-A design §1.2 MC-1, render half):

    * TENANT plane — the vaulted `full_name` resolves CLEAR and renders as a normal
      EDITABLE input (with a `name`, so it submits).
    * OPERATOR / impersonation plane — the SAME field resolves `%Masked{}` and
      `form_field/1` renders the read-only `••••` placeholder with NO `name`
      attribute: nothing an operator types can enter the params through it, and the
      vault token never reaches the DOM. The non-vaulted `job_title` stays
      editable — masking does not over-block.

  The seeded `display_name` deliberately does NOT appear on this form: it is a
  non-vaulted attribute that duplicates the person's name, so leaving it out keeps
  the operator-plane leak scan strict (any name fragment in the DOM = a failure).

  The form is `AshPhoenix.Form.for_update/3` over the PLANE-RESOLVED record (the
  same `Samen.Api.PiiResolution` chokepoint every read surface uses), so the masked
  value arrives in the form exactly as it would in A3's real edit modals. This
  LiveView never unwraps a `%Masked{}` and never calls the vault.
  """
  use Phoenix.LiveView

  import Samen.UI

  require Ash.Query

  alias Samen.Web.Mount

  @doc false
  def load(socket, org_id, contact_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    contact = read_contact(mount, scope, contact_id)

    form =
      contact
      |> AshPhoenix.Form.for_update(:update, scope: scope)
      |> to_form()

    assign(socket, org_id: org_id, contact: contact, form: form, saved: nil, deleted: nil)
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    {:noreply, assign(socket, form: AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
      {:ok, contact} -> {:noreply, assign(socket, saved: contact)}
      {:error, form} -> {:noreply, assign(socket, form: form)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    Mount.resource(mount, Person)
    |> Ash.get!(id, scope: scope)
    |> Ash.destroy!(scope: scope)

    {:noreply, assign(socket, deleted: id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="contact-edit-fixture">
      <.simple_form :let={f} for={@form} id="contact-edit-form" phx-change="validate" phx-submit="save">
        <.form_field field={f[:job_title]} label="Job title" />
        <.form_field field={f[:full_name]} label="Full name" />
        <:actions>
          <.button variant="primary" type="submit">Save</.button>
        </:actions>
      </.simple_form>
      <.delete_confirm :if={@contact} id="delete-contact" phx-click="delete" phx-value-id={@contact.id} />
    </div>
    """
  end

  # Bounded single-record read + the SAME PiiResolution chokepoint as every list/detail
  # surface (fail-safe: on resolver error the record stays masked — no plaintext downgrade).
  defp read_contact(mount, scope, id) do
    record =
      Mount.resource(mount, Person)
      |> Ash.Query.ensure_selected([:full_name, :emails, :phones, :display_name, :job_title])
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> nil
      record -> resolve_pii(record, mount, scope)
    end
  end

  defp resolve_pii(record, mount, scope) do
    [resolved] =
      Samen.Api.PiiResolution.resolve(
        [record],
        Mount.resource(mount, Person),
        actor_of(scope),
        repo: mount.repo
      )

    resolved
  rescue
    _ -> record
  end

  defp actor_of(%Samen.Scope{actor: actor}), do: actor
  defp actor_of(actor) when is_map(actor), do: actor
  defp actor_of(_), do: %{}
end
