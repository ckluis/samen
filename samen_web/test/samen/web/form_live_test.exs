defmodule Samen.Web.FormLiveTest do
  @moduledoc """
  A2 LiveView tests for the form/modal/empty-state primitives (ADR-016 §2/§5) against
  the fixtures (`Samen.WebTest.FormFixture.{CompanyFormLive, ContactEditLive}`),
  driving real Ash writes on the scratch repo:

    * `empty_state` at zero rows with working `:actions` + `:sample` events (AC-G5-1
      component proof).
    * "New …" opens the `modal` + `simple_form` (AC-G1-1 shape); an INVALID submit
      renders inline `form_field` errors and persists NOTHING (AC-G1-2 red half); a
      valid submit persists + refreshes the bounded list + closes the modal
      (AC-G1-2 green half).
    * `delete_confirm` carries the data-confirm interlock; `delete` destroys the row.
    * **THE PER-PLANE FORM-MASKING GUARANTEE (MC-1 render half / RP-G1-7 render
      half):** the SAME edit form renders the vaulted `full_name` EDITABLE-CLEAR on
      the tenant plane and READ-ONLY `••••` with NO `name` attribute on the operator
      plane — plaintext AND vault token absent from the DOM, submit path closed by
      construction. (The Ash write-path rejection of an operator plaintext write is
      A3's Invariant L1.)
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.FormFixture.CompanyFormLive
  alias Samen.WebTest.FormFixture.ContactEditLive

  # ---------------------------------------------------------------------------
  # Harness (same posture as list_live_test: build a socket, call load/*, drive
  # handle_event/3 directly — the same code path the mounted route runs)
  # ---------------------------------------------------------------------------

  defp company_socket(org_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> CompanyFormLive.load(org_id)
  end

  defp contact_socket(org_id, contact_id, plane_opts) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> ContactEditLive.load(org_id, contact_id)
  end

  defp event(socket, module, name, params) do
    {:noreply, socket} = module.handle_event(name, params, socket)
    socket
  end

  defp company_count(org_id) do
    # org_id is not in the default select — ensure it so the org filter is non-vacuous.
    Samen.WebTest.Crm.Company
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  # ---------------------------------------------------------------------------
  # empty_state (AC-G5-1) — zero rows, CTA + sample affordances wired
  # ---------------------------------------------------------------------------

  test "a zero-row org renders the empty_state with a working CTA and sample affordance" do
    org_id = Ash.UUID.generate()
    socket = company_socket(org_id)

    html = render_html(CompanyFormLive, socket.assigns)
    assert html =~ ~s(class="card empty-state")
    assert html =~ "No companies yet"
    assert html =~ "Create your first company to get started."
    # The :actions CTA is a REAL button (phx-click) — not decorative (the G1 fix).
    assert html =~ ~s(id="empty-new-company")
    assert html =~ ~s(phx-click="open_modal")
    # The :sample slot affordance is wired too.
    assert html =~ ~s(id="load-sample")
    assert html =~ ~s(phx-click="load_sample")

    # Both events actually reach the view.
    socket = event(socket, CompanyFormLive, "load_sample", %{})
    assert socket.assigns.sample_requested

    socket = event(socket, CompanyFormLive, "open_modal", %{})
    assert socket.assigns.show_modal
  end

  # ---------------------------------------------------------------------------
  # modal + simple_form create (AC-G1-1 shape, AC-G1-2 both halves)
  # ---------------------------------------------------------------------------

  test "open_modal renders the dialog hosting the AshPhoenix.Form-backed create form" do
    org_id = Ash.UUID.generate()
    socket = company_socket(org_id) |> event(CompanyFormLive, "open_modal", %{})

    html = render_html(CompanyFormLive, socket.assigns)
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(phx-hook="Phoenix.FocusWrap")
    assert html =~ ~s(id="company-form")
    assert html =~ ~s(phx-submit="save")
    assert html =~ ~s(name="form[name]")

    # close_modal (the escape/click-away/✕ target) hides it again.
    socket = event(socket, CompanyFormLive, "close_modal", %{})
    refute render_html(CompanyFormLive, socket.assigns) =~ ~s(role="dialog")
  end

  test "RED PATH pairing: an INVALID submit shows inline field errors and persists NOTHING" do
    org_id = Ash.UUID.generate()
    socket = company_socket(org_id) |> event(CompanyFormLive, "open_modal", %{})

    # `name` is allow_nil?: false — an empty submit must fail with an inline error.
    socket = event(socket, CompanyFormLive, "save", %{"form" => %{"name" => "", "notes" => "no name"}})

    # The modal stays open with the inline error rendered on the field (AC-G1-2).
    assert socket.assigns.show_modal
    html = render_html(CompanyFormLive, socket.assigns)
    assert html =~ ~s(class="field field-invalid")
    assert html =~ ~s(class="field-error")
    assert html =~ "is required"
    assert html =~ ~s(aria-invalid="true")

    # Nothing was persisted, the list did not change.
    assert company_count(org_id) == 0
    assert socket.assigns.companies == []
    assert socket.assigns.saved == nil
  end

  test "a VALID submit persists through Ash, closes the modal, and refreshes the bounded list" do
    org_id = Ash.UUID.generate()
    socket = company_socket(org_id) |> event(CompanyFormLive, "open_modal", %{})

    socket =
      event(socket, CompanyFormLive, "save", %{
        "form" => %{"name" => "Northwind Freight Co", "notes" => "created via kit form"}
      })

    refute socket.assigns.show_modal
    assert socket.assigns.saved.name == "Northwind Freight Co"
    assert company_count(org_id) == 1

    # The refreshed list renders the new row (and no longer the empty state).
    html = render_html(CompanyFormLive, socket.assigns)
    assert html =~ "Northwind Freight Co"
    refute html =~ ~s(class="card empty-state")
  end

  test "validate re-renders the form live (phx-change) without persisting" do
    org_id = Ash.UUID.generate()
    socket = company_socket(org_id) |> event(CompanyFormLive, "open_modal", %{})

    socket = event(socket, CompanyFormLive, "validate", %{"form" => %{"name" => "Acme"}})
    assert render_html(CompanyFormLive, socket.assigns) =~ ~s(value="Acme")
    assert company_count(org_id) == 0
  end

  # ---------------------------------------------------------------------------
  # delete_confirm + delete (the destructive interlock)
  # ---------------------------------------------------------------------------

  test "each row carries the data-confirm interlock and delete destroys through Ash" do
    org_id = Ash.UUID.generate()
    socket = company_socket(org_id) |> event(CompanyFormLive, "open_modal", %{})
    socket = event(socket, CompanyFormLive, "save", %{"form" => %{"name" => "Doomed Co"}})
    [company] = socket.assigns.companies

    html = render_html(CompanyFormLive, socket.assigns)
    assert html =~ ~s(data-confirm="Delete this record? This cannot be undone.")
    assert html =~ ~s(phx-click="delete")
    assert html =~ ~s(phx-value-id="#{company.id}")

    socket = event(socket, CompanyFormLive, "delete", %{"id" => company.id})
    assert socket.assigns.deleted == company.id
    assert socket.assigns.companies == []
    assert company_count(org_id) == 0
    # Back to the empty state after the last row is gone.
    assert render_html(CompanyFormLive, socket.assigns) =~ ~s(class="card empty-state")
  end

  # ===========================================================================
  # THE PER-PLANE FORM-MASKING GUARANTEE (MC-1 render half / RP-G1-7 render
  # half) — the SAME edit form on both planes.
  # ===========================================================================

  test "TENANT plane: the vaulted full_name renders as a normal EDITABLE input, clear" do
    %{org_id: org_id, crm: %{person: person}} = Seeds.seed_all()
    socket = contact_socket(org_id, person.id, plane: :tenant)

    html = render_html(ContactEditLive, socket.assigns)

    # The vaulted field is editable — it has a name and submits with the form.
    assert html =~ ~s(name="form[full_name]")
    refute html =~ "data-masked"
    # …and the tenant sees their OWN contact's PII in the clear.
    assert html =~ "Aurelia"
    assert html =~ "Sentinelson"
    # The non-vaulted job_title is a normal editable field too.
    assert html =~ ~s(name="form[job_title]")
    assert html =~ "Head of Logistics"
  end

  test "OPERATOR plane RED PATH: the SAME form renders full_name READ-ONLY •••• — no name attr, no plaintext, no token" do
    %{org_id: org_id, crm: %{person: person}} = Seeds.seed_all()
    socket = contact_socket(org_id, person.id, plane: :operator, target_org_id: org_id)

    html = render_html(ContactEditLive, socket.assigns)

    # Non-vacuous: it IS the same form with the same fields…
    assert html =~ ~s(id="contact-edit-form")
    assert html =~ "Full name"
    # …but the vaulted field is the read-only masked placeholder…
    assert html =~ "data-masked"
    assert html =~ "••••"
    refute html =~ ~s(name="form[full_name]")
    # …with the plaintext ABSENT (any name fragment in the DOM = leak)…
    refute html =~ "Aurelia"
    refute html =~ "Sentinelson"
    refute html =~ Seeds.contact_email()
    refute html =~ Seeds.contact_phone()
    # …and the vault token NEVER reaches the DOM (the RP leak scan).
    refute html =~ "vt_"
    # Masking does not over-block: the non-vaulted job_title stays editable.
    assert html =~ ~s(name="form[job_title]")
    assert html =~ "Head of Logistics"
  end

  test "tenant edit round-trips: a save through the kit form persists the change" do
    %{org_id: org_id, crm: %{person: person}} = Seeds.seed_all()
    socket = contact_socket(org_id, person.id, plane: :tenant)

    socket = event(socket, ContactEditLive, "save", %{"form" => %{"job_title" => "VP Logistics"}})
    assert socket.assigns.saved.job_title == "VP Logistics"

    reloaded =
      Samen.WebTest.Crm.Person
      |> Ash.get!(person.id, authorize?: false)

    assert reloaded.job_title == "VP Logistics"
  end
end
