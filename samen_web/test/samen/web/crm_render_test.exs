defmodule Samen.Web.CRMRenderTest do
  @moduledoc """
  Framework CRM render tests against the standalone test-support host (ADR-009 §6). Proves:

    1. Each CRM page renders 200-equivalent with REAL seeded rows (non-vacuous).
    2. THE TWO-PLANE MASKING GUARANTEE — the SAME `Samen.Web.CRM.ContactsLive` renders a
       seeded contact's name/email/phone IN THE CLEAR on the tenant plane, and the SAME
       contact `••••` on the operator plane, with the vault token ABSENT.

  This is the reusable proof: the masking guarantee is a framework-local test, independent of
  any vertical.
  """
  use Samen.WebTest.DataCase, async: false

  setup do
    %{org_id: org_id} = Seeds.seed_all()
    %{org_id: org_id}
  end

  test "/crm/companies renders the app shell + seeded company", %{org_id: org_id} do
    mount = build_mount(:crm)
    html = render_live(Samen.Web.CRM.CompaniesLive, mount, [org_id])

    assert html =~ ~s(class="app")
    assert html =~ "<table>"
    assert html =~ "Northwind Freight Co"
    assert html =~ "company-row"
  end

  test "/crm/pipeline renders the seeded opportunity grouped by stage", %{org_id: org_id} do
    mount = build_mount(:crm)
    html = render_live(Samen.Web.CRM.PipelineLive, mount, [org_id])

    assert html =~ "Chicago → Dallas dry van"
    assert html =~ "Quoted"
  end

  # ==========================================================================
  # THE TWO-PLANE MASKING GUARANTEE (the load-bearing test)
  # ==========================================================================

  test "TENANT plane: /crm/contacts renders the contact's PII in the clear", %{org_id: org_id} do
    mount = build_mount(:crm, plane: :tenant)
    html = render_live(Samen.Web.CRM.ContactsLive, mount, [org_id])

    # Non-vacuous: the seeded row is present.
    assert html =~ "contact-row"
    # PII IN THE CLEAR — the tenant reads its own contact's name/email/phone.
    assert html =~ Seeds.contact_full_name()
    assert html =~ Seeds.contact_email()
    assert html =~ Seeds.contact_phone()
  end

  test "OPERATOR plane: /crm/contacts renders the SAME contact masked ••••, PII absent", %{org_id: org_id} do
    mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.CRM.ContactsLive, mount, [org_id])

    # Non-vacuous: the SAME seeded row is present (the operator opened the tenant).
    assert html =~ "contact-row"
    # Masked sentinel present.
    assert html =~ "••••"
    # PII ABSENT — the plaintext name/email/phone do NOT appear.
    refute html =~ Seeds.contact_full_name()
    refute html =~ Seeds.contact_email()
    refute html =~ Seeds.contact_phone()
  end

  test "RED PATH: the operator render never leaks a vault token", %{org_id: org_id} do
    mount = build_mount(:crm, plane: :operator, target_org_id: org_id)
    html = render_live(Samen.Web.CRM.ContactsLive, mount, [org_id])

    # No vault token prefix leaks into the DOM on the operator plane.
    refute html =~ "vt_"
    refute html =~ "pii_"
    refute html =~ Seeds.contact_email()
  end
end
