defmodule Samen.Web.CRMCompanyDetailCrudTest do
  @moduledoc """
  A3 WIRING (crm batch) — the WRITE side of `Samen.Web.CRM.CompanyLive` (the non-PII
  detail surface with a PII SUB-LIST): the edit modal, delete, and the kit-form
  log-activity composer.

    * **Edit (AC-G1-1/2)** — "Edit company" opens the `AshPhoenix.Form.for_update`
      modal; a valid save persists + re-renders; an INVALID save (blank required
      `name`) renders inline errors and persists NOTHING.
    * **Log-activity (AC-G1-1/2)** — the composer is the kit `simple_form`: a valid
      submit creates a company-linked `<ns>.Activity` that appears in the re-rendered
      timeline; an invalid submit (blank required `type`) renders inline errors and
      persists NOTHING.
    * **Delete** — `delete_confirm/1` interlock + destroy + navigate back to the
      companies list; FAIL-HONEST red path: the seeded company has linked
      person/opportunity/activity rows, the kernel defines no cascade, so the destroy
      is REFUSED and the refusal is SURFACED (no silent navigate).
    * **PER-PLANE MASKING (MC on the newly write-enabled surface)** — Company itself
      is non-PII, but the Overview tab renders this company's CONTACTS sub-list
      (name/email through `PiiResolution`): tenant reads it CLEAR, the operator plane
      renders the SAME rows `••••` with plaintext AND vault token absent — and offers
      NO write affordance (edit/delete/composer are tenant-plane posture).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.CompanyLive

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, company_id: seeded.crm.company.id}
  end

  # -- harness (same shape as crm_contact_detail_crud_test.exs) -----------------

  defp mount_socket(org_id, company_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:crm, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> CompanyLive.load(org_id, company_id)
  end

  defp html(socket), do: render_html(CompanyLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = CompanyLive.handle_event(name, params, socket)
    socket
  end

  defp raw_company(id), do: Ash.get!(Samen.WebTest.Crm.Company, id, authorize?: false)

  defp activity_count(org_id) do
    Samen.WebTest.Crm.Activity
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> Enum.count(&(&1.org_id == org_id))
  end

  defp fresh_company(org_id, name) do
    Samen.WebTest.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name}, authorize?: false)
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------
  # Edit — tenant green path (AC-G1-1)
  # ---------------------------------------------------------------------------

  test "TENANT: Edit company opens the for_update modal; a valid save persists + re-renders",
       %{org_id: org_id, company_id: company_id} do
    socket = mount_socket(org_id, company_id)

    rendered = html(socket)
    assert rendered =~ ~s(id="edit-company")
    assert rendered =~ ~s(phx-click="edit_company")

    socket = event(socket, "edit_company", %{})
    rendered = html(socket)
    assert rendered =~ ~s(id="edit-company-modal")
    assert rendered =~ ~s(role="dialog")
    assert rendered =~ ~s(name="form[name]")
    assert rendered =~ "Northwind Freight Co"

    socket =
      event(socket, "save_edit", %{
        "form" => %{"name" => "Northwind Freight Company", "industry" => "Logistics"}
      })

    refute socket.assigns.show_edit
    rendered = html(socket)
    assert rendered =~ "Northwind Freight Company"
    assert rendered =~ "Logistics"

    raw = raw_company(company_id)
    assert raw.name == "Northwind Freight Company"
    assert raw.industry == "Logistics"
  end

  test "RED PATH (AC-G1-2): an INVALID edit (blank required name) shows inline errors and persists NOTHING",
       %{org_id: org_id, company_id: company_id} do
    socket = mount_socket(org_id, company_id) |> event("edit_company", %{})

    socket = event(socket, "save_edit", %{"form" => %{"name" => ""}})

    # Modal stays open with the inline field error (AC-G1-2).
    assert socket.assigns.show_edit
    rendered = html(socket)
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert rendered =~ "is required"
    # DB provably unchanged.
    assert raw_company(company_id).name == "Northwind Freight Co"
  end

  # ---------------------------------------------------------------------------
  # Log-activity — the kit-form composer on the company timeline (AC-G1-1/2)
  # ---------------------------------------------------------------------------

  test "log_activity creates a company-linked Activity and it appears in the re-rendered timeline",
       %{org_id: org_id, company_id: company_id} do
    before_count = activity_count(org_id)

    socket =
      mount_socket(org_id, company_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    assert html(socket) =~ ~s(id="log-activity-form")

    socket =
      event(socket, "log_activity", %{
        "activity" => %{"type" => "call", "subject" => "Carrier onboarding call", "body" => "Docs received."}
      })

    assert activity_count(org_id) == before_count + 1
    rendered = html(socket)
    assert rendered =~ "Carrier onboarding call"

    # The new row is company-linked (the server-side fact, never client input).
    linked =
      Samen.WebTest.Crm.Activity
      |> Ash.Query.ensure_selected([:subject, :company_id])
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.subject == "Carrier onboarding call"))

    assert linked.company_id == company_id
  end

  test "RED PATH (AC-G1-2): an invalid composer submit (blank required type) shows inline errors, persists NOTHING",
       %{org_id: org_id, company_id: company_id} do
    before_count = activity_count(org_id)

    socket =
      mount_socket(org_id, company_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    socket =
      event(socket, "log_activity", %{
        "activity" => %{"type" => "", "subject" => "Half-written note"}
      })

    rendered = html(socket)
    assert rendered =~ ~s(id="log-activity-form")
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert rendered =~ "is required"
    assert activity_count(org_id) == before_count
  end

  # ---------------------------------------------------------------------------
  # Delete — interlock + destroy + navigate back; fail-honest refusal
  # ---------------------------------------------------------------------------

  test "TENANT: delete carries the interlock, destroys the company, and navigates back to the list",
       %{org_id: org_id} do
    # A FRESH company with no linked rows — deletable under the kernel's FK rules.
    company = fresh_company(org_id, "Deletable Freight Co")
    socket = mount_socket(org_id, company.id)

    rendered = html(socket)
    assert rendered =~ ~s(id="delete-company")
    assert rendered =~ ~s(data-confirm="Delete this company? This cannot be undone.")

    socket = event(socket, "delete_company", %{"id" => company.id})

    assert {:live, :redirect, %{to: to}} = socket.redirected
    assert to =~ "/crm/companies"

    assert_raise Ash.Error.Invalid, fn -> raw_company(company.id) end
  end

  test "FAIL-HONEST RED PATH: deleting a company with linked records is REFUSED and SURFACED — no silent navigate",
       %{org_id: org_id, company_id: company_id} do
    # The seeded company HAS a person + opportunity + activity; no cascade in the
    # kernel, so the DB refuses. The page must surface the refusal, not navigate.
    socket = mount_socket(org_id, company_id)
    socket = event(socket, "delete_company", %{"id" => company_id})

    assert socket.redirected == nil
    assert socket.assigns.delete_error =~ "Could not delete this company"
    assert html(socket) =~ ~s(id="delete-error")
    # The company provably still exists.
    assert raw_company(company_id).id == company_id
  end

  # ---------------------------------------------------------------------------
  # PER-PLANE MASKING on the contacts sub-list + operator write posture
  # ---------------------------------------------------------------------------

  test "TENANT: the Overview contacts sub-list renders the seeded contact CLEAR (non-vacuous control)",
       %{org_id: org_id, company_id: company_id} do
    rendered = html(mount_socket(org_id, company_id))

    assert rendered =~ "cc-contact-row"
    assert rendered =~ Seeds.contact_full_name()
    assert rendered =~ Seeds.contact_email()
  end

  test "OPERATOR: the SAME sub-list masks name/email •••• AND the page offers no write affordance",
       %{org_id: org_id, company_id: company_id} do
    socket = mount_socket(org_id, company_id, plane: :operator, target_org_id: org_id)
    rendered = html(socket)

    # Non-vacuous: the company header + the SAME contact row render for the operator…
    assert rendered =~ "Northwind Freight Co"
    assert rendered =~ "cc-contact-row"
    # …with the PII masked — plaintext AND vault token absent (any fragment = leak).
    assert rendered =~ "••••"
    refute rendered =~ Seeds.contact_full_name()
    refute rendered =~ Seeds.contact_email()
    refute rendered =~ Seeds.contact_phone()
    refute rendered =~ "vt_"
    # And no write affordance: no edit/delete/composer (tenant-plane posture; the
    # kernel's OrgScope + WriteGuard enforce regardless).
    refute rendered =~ ~s(id="edit-company")
    refute rendered =~ ~s(id="delete-company")
    refute rendered =~ "data-confirm"

    operator_activity =
      socket
      |> Phoenix.Component.assign(:active_tab, "activity")
      |> then(&render_html(CompanyLive, &1.assigns))

    refute operator_activity =~ ~s(id="log-activity-form")
  end
end
