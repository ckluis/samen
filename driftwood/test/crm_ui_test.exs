defmodule Driftwood.CrmUiTest do
  @moduledoc """
  CRM UI smoke tests — the inherited CRM module rendered by the FRAMEWORK (ADR-009).

  The CRM pages are no longer driftwood-local: they are `Samen.Web.CRM.{Companies,Contacts,
  Pipeline}Live`, MOUNTED by `DriftwoodWeb.Router` (`samen_module_routes :crm, Driftwood.Crm,
  repo: Driftwood.Repo`) over Driftwood's materialized `Driftwood.Crm.*` resources. The DEEP
  render/masking coverage now lives in samen_web's own suite (`web/crm_render_test.exs`,
  independent of any vertical). These driftwood-side tests prove Driftwood's OWN MOUNT is
  correct — the framework LiveViews render Driftwood's rows on both planes:

    1. Each mounted CRM page renders with Driftwood's seeded rows (non-vacuous).
    2. MASKING (the tenant-owner rule, kept end-to-end over the driftwood mount):
       a. TENANT plane — a contact's name/email/phone render IN THE CLEAR (the org reads
          its own contacts' PII, no operator reveal grant).
       b. OPERATOR / impersonation plane — the SAME contact renders •••• and the plaintext
          PII is ABSENT. ONE code path (`Samen.Web.CRM.ContactsLive.load/2`), differing only
          in the mount's plane.

  The mount + render is driven through `Driftwood.DataCase.{driftwood_mount,render_framework}`,
  which builds the identical `Samen.Web.Mount` the router builds and renders the framework
  LiveView over it — the exact code path the mounted route runs.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Seeds
  alias Samen.Web.CRM

  setup do
    org_id = Ecto.UUID.generate()
    :ok = Seeds.run(org_id)
    assert Seeds.demo_all(org_id) == org_id
    %{org_id: org_id}
  end

  # ==========================================================================
  # MOUNTED ROUTES render Driftwood's seeded rows
  # ==========================================================================

  test "the mounted /crm/companies renders the app shell + Driftwood's seeded companies", %{org_id: org_id} do
    mount = driftwood_mount(:crm)
    html = render_framework(CRM.CompaniesLive, mount, [org_id])

    # Structural: the framework app shell + data table are present.
    assert html =~ ~s(class="app")
    assert html =~ ~s(class="side")
    assert html =~ "<table>"
    assert html =~ ~s(class="card")

    # Non-vacuous: Driftwood's seeded company appears through the framework page (a Blue Ridge
    # carrier — the default spec's own book).
    assert html =~ "Appalachian Freight Lines"
    assert html =~ "company-row"

    # Metric cards rendered.
    assert html =~ ~s(class="metrics")
    assert html =~ "Companies"
    assert html =~ "Contacts"
    assert html =~ "Pipeline value"

    # Non-PII: no vault token leaks; companies have no PII to mask.
    refute html =~ "vt_"
    refute html =~ "••••"
  end

  test "the mounted /crm/pipeline renders Driftwood's seeded opportunities", %{org_id: org_id} do
    mount = driftwood_mount(:crm)
    html = render_framework(CRM.PipelineLive, mount, [org_id])

    assert html =~ ~s(class="app")
    assert html =~ "<table>"
    # The seeded opportunity/load name (BR-44 lane) appears.
    assert html =~ "BR-44"
    assert html =~ "Pipeline value"

    refute html =~ "vt_"
    refute html =~ "••••"
  end

  # ==========================================================================
  # MASKING over the driftwood mount — tenant clear / operator ••••
  # ==========================================================================

  describe "CRM contacts PII masking over the Driftwood mount (F2 — tenant-owner rule)" do
    test "TENANT plane: /crm/contacts renders a contact's PII IN THE CLEAR", %{org_id: org_id} do
      mount = driftwood_mount(:crm, plane: :tenant)
      html = render_framework(CRM.ContactsLive, mount, [org_id])

      # Non-vacuous: the seeded contact row is present.
      assert html =~ "contact-row"

      # PII IN THE CLEAR — the tenant reads its own contact's name/email/phone.
      assert html =~ "Dana", "tenant plane did not render contact name in the clear"
      assert html =~ ~r/[a-z.]+@[a-z.]+\.example/,
             "tenant plane did not render a contact email in the clear (composite decode regressed)"
      assert html =~ ~r/\d{3}-\d{4}/,
             "tenant plane did not render a contact phone in the clear (composite decode regressed)"

      # The vault token itself NEVER renders (plaintext came through the decrypt chokepoint).
      refute html =~ "vt_"
    end

    test "OPERATOR/impersonation plane: the SAME contact renders •••• (no plaintext leak)", %{org_id: org_id} do
      mount = driftwood_mount(:crm, plane: :operator, target_org_id: org_id)
      html = render_framework(CRM.ContactsLive, mount, [org_id])

      # Non-vacuous: the SAME seeded row is present (operator opened the tenant org).
      assert html =~ "contact-row"

      # MUST render •••• (the %Masked{} sentinel on the impersonation plane).
      assert html =~ "••••", "operator/impersonation plane did not mask contact PII"

      # MUST NOT render any seeded plaintext name/email.
      refute html =~ "Whitfield", "operator plane leaked contact's last name in plaintext"
      refute html =~ "dana.whitfield", "operator plane leaked contact's email in plaintext"

      # MUST NOT render vault tokens.
      refute html =~ "vt_"
    end

    test "CROSS-ORG: a tenant mount for a DIFFERENT org sees ZERO contacts (org-scope isolation)", %{org_id: _org_id} do
      other_org = Ecto.UUID.generate()
      mount = driftwood_mount(:crm, plane: :tenant)
      html = render_framework(CRM.ContactsLive, mount, [other_org])

      # No PII from the scenario org — neither clear nor masked.
      refute html =~ "Dana"
      refute html =~ "Whitfield"
      refute html =~ "vt_"
    end
  end
end
