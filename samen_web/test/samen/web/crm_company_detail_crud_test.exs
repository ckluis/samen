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
      companies list. ADR-040 §5.9/T37c: `Company` is `archivable true`, so the
      default destroy now soft-archives (T36); CRM declares no cascade (§5.4), so
      a company with linked person/opportunity rows archives cleanly too — its
      children stay live, untouched.
    * **PER-PLANE MASKING (MC on the newly write-enabled surface)** — Company itself
      is non-PII, but the Overview tab renders this company's CONTACTS sub-list
      (name/email through `PiiResolution`): tenant reads it CLEAR, the operator plane
      renders the SAME rows `••••` with plaintext AND vault token absent — and offers
      NO write affordance (edit/delete/composer are tenant-plane posture).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

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

  defp archived_company(id) do
    Samen.WebTest.Crm.Company
    |> Ash.Query.for_read(:archived)
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.id == id))
  end

  # ADR-041 §5: the log-activity composer now writes a canonical Work Task. Count Tasks.
  defp activity_count(org_id) do
    Samen.WebTest.Work.Task
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

  test "log_activity creates a company-anchored Work Task and it appears in the re-rendered timeline",
       %{org_id: org_id, company_id: company_id} do
    before_count = activity_count(org_id)

    socket =
      mount_socket(org_id, company_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    assert html(socket) =~ ~s(id="log-activity-form")

    # ADR-041 §6.1: the composer writes a Work Task with the Task field names (kind/title);
    # the LiveView merges the crm.company subject anchor.
    socket =
      event(socket, "log_activity", %{
        "activity" => %{"kind" => "call", "title" => "Carrier onboarding call", "body" => "Docs received."}
      })

    assert activity_count(org_id) == before_count + 1
    rendered = html(socket)
    assert rendered =~ "Carrier onboarding call"

    # The new Task is company-ANCHORED via the generic object-ref (subject_key/subject_id) —
    # the server-side fact, never client input (no CRM FK).
    linked =
      Samen.WebTest.Work.Task
      |> Ash.Query.ensure_selected([:title, :subject_key, :subject_id])
      |> Ash.read!(authorize?: false)
      |> Enum.find(&(&1.title == "Carrier onboarding call"))

    assert linked.subject_key == "crm.company"
    assert linked.subject_id == company_id
  end

  test "RED PATH (AC-G1-2): an invalid composer submit (out-of-enum kind) shows inline errors, persists NOTHING",
       %{org_id: org_id, company_id: company_id} do
    before_count = activity_count(org_id)

    socket =
      mount_socket(org_id, company_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    # ADR-041 §6.1: the composer writes a Work Task; `kind` is a bounded one_of enum — an
    # out-of-enum value is refused + surfaced inline, persisting nothing (AC-G1-2 red path).
    socket =
      event(socket, "log_activity", %{
        "activity" => %{"kind" => "not_a_valid_kind", "title" => "Half-written note"}
      })

    rendered = html(socket)
    assert rendered =~ ~s(id="log-activity-form")
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert activity_count(org_id) == before_count
  end

  # ---------------------------------------------------------------------------
  # Delete — interlock + soft-archive + navigate back (ADR-040 §5.9/T37c)
  # ---------------------------------------------------------------------------

  test "TENANT: delete carries the interlock, soft-archives the company, and navigates back to the list",
       %{org_id: org_id} do
    company = fresh_company(org_id, "Deletable Freight Co")
    socket = mount_socket(org_id, company.id)

    rendered = html(socket)
    assert rendered =~ ~s(id="delete-company")
    assert rendered =~ ~s(data-confirm="Delete this company? This cannot be undone.")

    socket = event(socket, "delete_company", %{"id" => company.id})

    assert {:live, :redirect, %{to: to}} = socket.redirected
    assert to =~ "/crm/companies"

    # `raw_company/1` reads through the default (archived-excluding) filter — the
    # archived company drops out, same observable shape as the old hard delete for
    # THIS assertion, even though the row still exists (T36 soft-destroy).
    assert_raise Ash.Error.Invalid, fn -> raw_company(company.id) end
    assert archived_company(company.id).archived_at
  end

  test "delete soft-archives a company WITH linked person/opportunity rows too (no FK refusal — ADR-040 §5.4 declares no cascade)",
       %{org_id: org_id, company_id: company_id} do
    # The seeded company HAS a person + opportunity; CRM declares no cascade
    # (§5.4), so the destroy is no longer a real DELETE for Postgres to refuse —
    # it soft-archives and the page navigates away, exactly like the bare case.
    socket = mount_socket(org_id, company_id)
    socket = event(socket, "delete_company", %{"id" => company_id})

    # The redirect itself proves success (the error branch never navigates —
    # see the TENANT test above and the handler's `case` in company_live.ex).
    assert {:live, :redirect, %{to: to}} = socket.redirected
    assert to =~ "/crm/companies"
    assert archived_company(company_id).archived_at

    # The linked Person/Opportunity rows are untouched (no cascade) — still live
    # and still pointing at the now-archived company.
    assert Samen.WebTest.Crm.Person
           |> Ash.Query.filter(company_id == ^company_id)
           |> Ash.read!(authorize?: false)
           |> Enum.any?()

    assert Samen.WebTest.Crm.Opportunity
           |> Ash.Query.filter(company_id == ^company_id)
           |> Ash.read!(authorize?: false)
           |> Enum.any?()
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
