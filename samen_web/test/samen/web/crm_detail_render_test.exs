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

  test "log_activity creates a canonical Work Task (anchored to the contact) and it appears in the re-rendered timeline", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm, plane: :tenant)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Samen.Web.CRM.ContactLive.load(org_id, contact_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    # ADR-041 §6.1: the composer form now writes a Work Task — the fields are the Task
    # names (kind/title/body), the LiveView merges the crm.person subject anchor.
    params = %{"activity" => %{"kind" => "call", "title" => "COMPOSER-CREATED check call", "body" => "Logged from the composer."}}
    {:noreply, socket} = Samen.Web.CRM.ContactLive.handle_event("log_activity", params, socket)

    # A3: the composer is the AshPhoenix.Form-backed kit form now — a successful submit
    # assigns a FRESH form (no lingering errors), not a form_error string.
    assert socket.assigns.activity_form.errors == []
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
      |> Phoenix.Component.assign(:samen_acting_as, false)
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

    # Task.title carries the former Activity.subject (ADR-041 §5.1).
    acts = Reads.activities_for_person(mount, scope, contact_id)
    subjects = Enum.map(acts, & &1.title)
    assert Seeds.activity_call_subject() in subjects
    assert Seeds.activity_note_subject() in subjects
    # The company-only activity is NOT in the person stream.
    refute "QBR scheduled" in subjects
  end

  test "MULTI-ANCHOR (§6.1): a migrated Task whose company link lives ONLY in custom.crm_refs appears in BOTH the contact and company timelines",
       %{org_id: org_id, contact_id: contact_id, company_id: company_id} do
    # A Task primary-anchored to the CONTACT (crm.person) whose COMPANY link survives ONLY in
    # custom.crm_refs — the multi-anchored migrated-Activity shape (ADR-041 §6.1). Raw-inserted
    # because the Tier-1 custom-bag guard refuses an Ash-written crm_refs; this is exactly the
    # shape the raw-SQL migration produces for an Activity linked to both a contact and a deal.
    seed_multi_anchor_task!(org_id, contact_id, company_id, "MULTI-ANCHOR-SENTINEL")

    mount = build_mount(:crm)
    scope = Mount.scope(mount, org_id)

    person_titles = Reads.activities_for_person(mount, scope, contact_id) |> Enum.map(& &1.title)
    company_titles = Reads.activities_for_company(mount, scope, company_id) |> Enum.map(& &1.title)

    # It appears in the CONTACT timeline (via the subject anchor) …
    assert "MULTI-ANCHOR-SENTINEL" in person_titles
    # … AND in the COMPANY timeline — which matches SOLELY via the custom.crm_refs OR-branch
    # (its subject_key is crm.person, not crm.company). Dropping that branch (the §11 sabotage,
    # scripts/sabotages/34-*) removes it here → this named test FAILS. Refutable by construction.
    assert "MULTI-ANCHOR-SENTINEL" in company_titles

    # POSITIVE CONTROL (anti-tautology): the company's OWN primary-anchored seeded activity
    # still shows, so the company read is non-vacuous independent of the crm_refs branch.
    assert "QBR scheduled" in company_titles
  end

  test "Reads.create_activity anchors a same-org contact (positive control) but a cross-org reference is INERT — refused (ADR-041 §6.1)", %{org_id: org_id, contact_id: contact_id} do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, org_id)

    # POSITIVE CONTROL (anti-tautology): a SAME-ORG person reference resolves through the
    # org-scoped ObjectRef and the Work Task is created + anchored.
    ok_attrs = %{type: :note, subject: "same-org attach", status: :completed, person_id: contact_id, org_id: org_id}
    assert {:ok, task} = Reads.create_activity(mount, scope, ok_attrs)
    assert task.subject_key == "crm.person"
    assert task.subject_id == contact_id

    # RED PATH: a person id from a DIFFERENT org. Task's subject is a generic object-ref,
    # NOT a belongs_to — so SameOrgFk cannot target it; instead the org-scoped
    # `Samen.Web.ObjectRef.resolve/3` narrows the read to the actor's org, so the cross-org
    # id is unresolvable → the create refuses to anchor (INERT by construction, ADR-041 §6.1).
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

  # Raw-insert a Work Task carrying custom.crm_refs (the migration-only preservation bag —
  # an Ash write is refused by the Tier-1 custom-bag guard, so migrated multi-anchor rows
  # only ever arrive via raw SQL, which is what this reproduces). Primary anchor = crm.person;
  # the company link lives ONLY in crm_refs, so the company timeline must OR-match it.
  defp seed_multi_anchor_task!(org_id, person_id, company_id, title) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()

    Repo.query!(
      """
      INSERT INTO wwt_task
        (wwt_id, wwt_org_id, wwt_kind, wwt_title, wwt_status, wwt_priority,
         wwt_subject_key, wwt_subject_id, wwt_custom, wwt_inserted_at, wwt_updated_at)
      VALUES ($1, $2, 'note', $3, 'completed', 20, 'crm.person', $4, $5, $6, $6)
      """,
      [
        Ecto.UUID.dump!(Ash.UUID.generate()),
        Ecto.UUID.dump!(org_id),
        title,
        Ecto.UUID.dump!(person_id),
        %{"crm_refs" => %{"person_id" => person_id, "company_id" => company_id}},
        now
      ]
    )
  end

  # Load, flip to the Activity tab, render (mirrors the ticket-detail Details-tab rig).
  defp render_activity_tab(module, mount, org_id, subject_id) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> module.load(org_id, subject_id)
      |> Phoenix.Component.assign(:active_tab, "activity")

    render_html(module, socket.assigns)
  end
end
