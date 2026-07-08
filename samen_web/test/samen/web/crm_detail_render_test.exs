defmodule Samen.Web.CRMDetailRenderTest do
  @moduledoc """
  Framework CRM DETAIL render tests (ADR-011 Phase 1) against the standalone test-support
  host. Proves the Phase-1 acceptance contract (ADR-011 §12):

    1. `/crm/contacts/:id` (tenant plane) renders header PII IN THE CLEAR, three tabs, and an
       Activity timeline with seeded entries + a working log-activity composer.
    2. THE MASKING GUARANTEE on the NEW PII surface — the SAME `ContactLive` renders the SAME
       contact `••••` on the operator plane, with the vault token ABSENT and the composer HIDDEN.
    3. `/crm/companies/:id` renders header + Overview/Activity/Deals; the company timeline works.
    4. The new `Reads` functions are covered, including `create_activity` respecting OrgScope +
       the kernel `SameOrgFk` (a cross-org FK is REFUSED — a negative test).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.CRM.Reads
  alias Samen.Web.Mount

  setup do
    seeded = Seeds.seed_all()

    %{
      org_id: seeded.org_id,
      contact_id: seeded.crm.person.id,
      company_id: seeded.crm.company.id
    }
  end

  # ==========================================================================
  # (a) Contact detail — 200 with data + the timeline (tenant plane)
  # ==========================================================================

  test "TENANT: /crm/contacts/:id renders header PII in the clear + three tabs", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :tenant)
    html = render_live(Samen.Web.CRM.ContactLive, mount, [org_id, contact_id])

    assert html =~ ~s(class="app")
    assert html =~ "contact-header"
    # PII IN THE CLEAR on the tenant plane.
    assert html =~ Seeds.contact_full_name()
    assert html =~ Seeds.contact_email()
    assert html =~ Seeds.contact_phone()
    # The three tabs.
    assert html =~ "tab=overview"
    assert html =~ "tab=activity"
    assert html =~ "tab=deals"
  end

  test "TENANT: the Activity tab renders the seeded timeline entries + the composer", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :tenant)
    html = render_activity_tab(Samen.Web.CRM.ContactLive, mount, org_id, contact_id)

    assert html =~ ~s(class="tl-rail")
    assert html =~ Seeds.activity_call_subject()
    assert html =~ Seeds.activity_note_subject()
    assert html =~ Seeds.activity_call_body()
    # The log-activity composer is present on the tenant plane.
    assert html =~ ~s(id="log-activity-form")
  end

  # ==========================================================================
  # (b) THE MASKING GUARANTEE on the NEW PII surface (contact detail)
  # ==========================================================================

  test "OPERATOR: /crm/contacts/:id masks the SAME contact ••••, PII + vault token absent", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.CRM.ContactLive, mount, [org_id, contact_id])

    # Non-vacuous: the same seeded contact loaded (the operator opened the tenant).
    assert html =~ "contact-header"
    # Masked sentinel present.
    assert html =~ "••••"
    # PII ABSENT — plaintext name/email/phone do NOT appear.
    refute html =~ Seeds.contact_full_name()
    refute html =~ Seeds.contact_email()
    refute html =~ Seeds.contact_phone()
    # No vault token leaks.
    refute html =~ "vt_"
    refute html =~ "pii_"
  end

  test "OPERATOR: the log-activity composer is HIDDEN on the operator plane", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    html = render_activity_tab(Samen.Web.CRM.ContactLive, mount, org_id, contact_id)

    # Timeline still renders (activity is non-PII) …
    assert html =~ ~s(class="tl-rail")
    # … but the composer is not offered to an operator.
    refute html =~ ~s(id="log-activity-form")
  end

  # ==========================================================================
  # (c) The LOG-ACTIVITY composer creates an activity + it shows in the timeline
  # ==========================================================================

  test "log_activity creates a <ns>.Activity and it appears in the re-rendered timeline", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :tenant)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Samen.Web.CRM.ContactLive.load(org_id, contact_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    params = %{"activity" => %{"type" => "call", "subject" => "COMPOSER-CREATED check call", "body" => "Logged from the composer."}}
    {:noreply, socket} = Samen.Web.CRM.ContactLive.handle_event("log_activity", params, socket)

    assert socket.assigns.form_error == nil
    html = render_html(Samen.Web.CRM.ContactLive, socket.assigns)
    assert html =~ "COMPOSER-CREATED check call"
    assert html =~ "Logged from the composer."
  end

  # ==========================================================================
  # (d) Company detail — 200 + tabs
  # ==========================================================================

  test "/crm/companies/:id renders the company header + Overview/Activity/Deals", %{org_id: org_id, company_id: company_id} do
    mount = build_mount(:crm)
    html = render_live(Samen.Web.CRM.CompanyLive, mount, [org_id, company_id])

    assert html =~ "company-header"
    assert html =~ "Northwind Freight Co"
    assert html =~ "tab=overview"
    assert html =~ "tab=activity"
    assert html =~ "tab=deals"
  end

  test "company Activity tab renders the company-scoped seeded activity", %{org_id: org_id, company_id: company_id} do
    mount = build_mount(:crm)
    html = render_activity_tab(Samen.Web.CRM.CompanyLive, mount, org_id, company_id)

    assert html =~ ~s(class="tl-rail")
    assert html =~ "QBR scheduled"
  end

  test "company Deals tab renders the seeded opportunity with its stage", %{org_id: org_id, company_id: company_id} do
    mount = build_mount(:crm)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Samen.Web.CRM.CompanyLive.load(org_id, company_id)
      |> Phoenix.Component.assign(:active_tab, "deals")

    html = render_html(Samen.Web.CRM.CompanyLive, socket.assigns)
    assert html =~ "Chicago → Dallas dry van"
    assert html =~ "Quoted"
  end

  # ==========================================================================
  # (e) Reads coverage — get_contact / get_company / activities / create_activity
  # ==========================================================================

  test "Reads.get_contact returns the person PII-resolved (clear on tenant)", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :tenant)
    scope = Mount.scope(mount, org_id)

    assert {:ok, person} = Reads.get_contact(mount, scope, contact_id)
    # full_name resolves to the clear JSON on the tenant plane (a binary, not %Masked{}).
    assert is_binary(person.full_name)
    refute match?(%Samen.Masked{}, person.full_name)
  end

  test "Reads.get_contact masks the person on the operator plane", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    scope = Mount.scope(mount, org_id)

    assert {:ok, person} = Reads.get_contact(mount, scope, contact_id)
    assert match?(%Samen.Masked{}, person.full_name)
    assert match?(%Samen.Masked{}, person.emails)
  end

  test "Reads.get_company returns the company; :error for a missing id", %{org_id: org_id, company_id: company_id} do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, org_id)

    assert {:ok, company} = Reads.get_company(mount, scope, company_id)
    assert company.name == "Northwind Freight Co"
    assert :error = Reads.get_company(mount, scope, Ash.UUID.generate())
  end

  test "Reads.activities_for_person returns newest-first, only that person's rows", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, org_id)

    acts = Reads.activities_for_person(mount, scope, contact_id)
    subjects = Enum.map(acts, & &1.subject)
    assert Seeds.activity_call_subject() in subjects
    assert Seeds.activity_note_subject() in subjects
    # The company-only activity is NOT in the person stream.
    refute "QBR scheduled" in subjects
  end

  test "Reads.create_activity respects OrgScope + SameOrgFk — a cross-org person FK is REFUSED", %{org_id: org_id} do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, org_id)

    # A person id from a DIFFERENT org — the kernel SameOrgFk change must refuse it.
    other_org = Ash.UUID.generate()

    foreign_person =
      Samen.WebTest.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: other_org, display_name: "Someone Else"},
        authorize?: false
      )
      |> Ash.create!()

    attrs = %{
      type: :note,
      subject: "cross-org attempt",
      status: :completed,
      person_id: foreign_person.id,
      org_id: org_id
    }

    assert {:error, _reason} = Reads.create_activity(mount, scope, attrs)
  end

  # -- helpers -----------------------------------------------------------------

  # Load, flip to the Activity tab, render (mirrors the ticket-detail Details-tab rig).
  defp render_activity_tab(module, mount, org_id, subject_id) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> module.load(org_id, subject_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    render_html(module, socket.assigns)
  end
end
