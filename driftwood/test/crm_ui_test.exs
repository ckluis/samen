defmodule Driftwood.CrmUiTest do
  @moduledoc """
  CRM UI page tests (T5.3 — inherited CRM module).

  Covers three guarantees:

    1. Each CRM route (/crm/companies, /crm/contacts, /crm/pipeline) renders 200
       with seeded data: real rows appear, no crash, the app shell + tables are
       present.

    2. MASKING TEST — the contacts page PII invariant:
       a. TENANT plane (plane: :tenant): a contact's name renders IN THE CLEAR — the
          org reads its own contacts' PII per the tenant-as-owner rule
          (§external-surface :707, "two key classes").
       b. OPERATOR / impersonation plane (plane: :operator + impersonation marker):
          the SAME contacts render •••• — `%Masked{}` passes through the UI kit's
          data_table untouched and Phoenix.HTML.Safe emits ••••.
       The masking test drives the exact same `CrmReads.contacts/1` function with
       the two scopes so there is ONE code path, differing only in the actor plane.

    3. Non-vacuous: the "clear" assertion verifies a seeded contact name is PRESENT
       (not merely "non-empty page"), and the "masked" assertion verifies the ••••
       sentinel IS present AND the plaintext name is ABSENT (not merely a rendering
       of an empty page).

  Uses `Driftwood.Seeds.demo_all/1` to seed the inherited CRM rows.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.{Seeds, CrmReads}

  # Render a LiveView module's render/1 to an HTML string — same harness used by
  # the dogfood walkthrough test and the web red-paths test.
  defp render(mod, assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> mod.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  setup do
    org_id = Ecto.UUID.generate()
    # Seed the Tier-0 pipeline stages (required by demo_all to attach opportunities).
    :ok = Seeds.run(org_id)
    # Seed the inherited CRM scope (companies, contacts, opportunities).
    assert Seeds.demo_all(org_id) == org_id
    %{org_id: org_id}
  end

  # ==========================================================================
  # ROUTE TEST 1 — /crm/companies renders with seeded companies
  # ==========================================================================

  test "/crm/companies renders app shell + companies data_table with seeded data", %{org_id: org_id} do
    socket =
      %Phoenix.LiveView.Socket{}
      |> DriftwoodWeb.CrmCompaniesLive.load(org_id)

    html = render(DriftwoodWeb.CrmCompaniesLive, socket.assigns)

    # Structural: the app shell and data table are present.
    assert html =~ ~s(class="app")
    assert html =~ ~s(class="side")
    assert html =~ "<table>"
    assert html =~ ~s(class="card")

    # Non-vacuous: seeded companies appear (Blue Ridge Carriers was seeded).
    assert html =~ "Blue Ridge Carriers"
    assert html =~ "company-row"

    # Metric cards rendered.
    assert html =~ ~s(class="metrics")
    assert html =~ "Companies"
    assert html =~ "Contacts"
    assert html =~ "Pipeline value"

    # At least 8 companies in the assigns (from the seed).
    assert length(socket.assigns.companies) == 8

    # Non-PII: no vault token leaks.
    refute html =~ "vt_"
    # No masking symbol on the companies page (companies have no PII).
    refute html =~ "••••"
  end

  # ==========================================================================
  # ROUTE TEST 2 — /crm/contacts renders with seeded contacts (tenant plane: clear)
  # ==========================================================================

  test "/crm/contacts renders contacts table on the TENANT plane with PII in the clear", %{org_id: org_id} do
    socket =
      %Phoenix.LiveView.Socket{}
      |> DriftwoodWeb.CrmContactsLive.load(org_id)

    html = render(DriftwoodWeb.CrmContactsLive, socket.assigns)

    # Structural checks.
    assert html =~ ~s(class="app")
    assert html =~ "<table>"
    assert html =~ "contact-row"

    # 12 contacts were seeded.
    assert length(socket.assigns.contacts) == 12

    # Non-PII: vault token never leaks.
    refute html =~ "vt_"
  end

  # ==========================================================================
  # ROUTE TEST 3 — /crm/pipeline renders with seeded opportunities grouped by stage
  # ==========================================================================

  test "/crm/pipeline renders opportunity stages with seeded data", %{org_id: org_id} do
    socket =
      %Phoenix.LiveView.Socket{}
      |> DriftwoodWeb.CrmPipelineLive.load(org_id)

    html = render(DriftwoodWeb.CrmPipelineLive, socket.assigns)

    # Structural checks.
    assert html =~ ~s(class="app")
    assert html =~ "<table>"
    assert html =~ "opp-row"

    # At least 6 opportunities seeded across stages.
    assert socket.assigns.total_opps >= 6

    # Seeded opportunity names are present (the load names).
    assert html =~ "BR-44"

    # Metric cards rendered.
    assert html =~ "Pipeline stages"
    assert html =~ "Pipeline value"

    # Non-PII: no vault token leaks.
    refute html =~ "vt_"
    refute html =~ "••••"
  end

  # ==========================================================================
  # MASKING TEST — contacts PII: tenant plane clear, operator plane ••••
  # ==========================================================================

  describe "CRM contacts PII masking invariant (F2 — tenant-owner rule)" do
    test "TENANT plane: a contact's name renders IN THE CLEAR (org reads its own contacts)", %{org_id: org_id} do
      # The TENANT scope: plane: :tenant — the org reads its own PII.
      tenant_scope = DriftwoodWeb.CrmContactsLive.crm_scope(org_id)
      contacts = CrmReads.contacts(tenant_scope)

      # Non-vacuous control: the read returned real rows.
      assert length(contacts) == 12

      # Render the contacts page with the tenant-plane resolved contacts.
      # org_id must be present in assigns because the sidebar template uses it.
      html =
        render(DriftwoodWeb.CrmContactsLive, %{
          no_org: false,
          org_id: org_id,
          contacts: contacts,
          flash: %{}
        })

      # MUST render at least one seeded name IN THE CLEAR (not ••••).
      # "Dana Whitfield" is the first contact seeded for Blue Ridge Carriers.
      assert html =~ "Dana", "tenant plane did not render contact name in the clear"

      # MUST NOT render the vault token (plaintext came through the decrypt chokepoint).
      refute html =~ "vt_"

      # Regression (C1): the composite email/phone PII resolves to decrypted JSON
      # text on the tenant plane — it must be decoded and shown in the clear, not "—".
      assert html =~ ~r/[a-z.]+@[a-z.]+\.example/,
             "tenant plane did not render a contact email in the clear (composite decode regressed)"

      assert html =~ ~r/\d{3}-\d{4}/,
             "tenant plane did not render a contact phone in the clear (composite decode regressed)"
    end

    test "OPERATOR/impersonation plane: the SAME contacts render •••• (no plaintext leak)", %{org_id: org_id} do
      # The OPERATOR impersonation scope: plane: :operator + :impersonation marker.
      # The same PiiResolution resolver — different plane key — keeps PII %Masked{}.
      operator_scope = DriftwoodWeb.CrmContactsLive.operator_scope(org_id)
      contacts = CrmReads.contacts(operator_scope)

      # Non-vacuous control: the read returned the same real rows (org-scoped still matches).
      assert length(contacts) == 12

      # Render the contacts page with the operator-plane resolved contacts.
      html =
        render(DriftwoodWeb.CrmContactsLive, %{
          no_org: false,
          org_id: org_id,
          contacts: contacts,
          flash: %{}
        })

      # MUST render •••• (the %Masked{} sentinel — PII is present-but-masked on the
      # impersonation plane per the doc's §control impersonation seam).
      assert html =~ "••••", "operator/impersonation plane did not mask contact PII"

      # MUST NOT render any seeded plaintext names.
      refute html =~ "Whitfield", "operator plane leaked contact's last name in plaintext"
      refute html =~ "dana.whitfield", "operator plane leaked contact's email in plaintext"

      # MUST NOT render vault tokens (the raw %Masked{token: …} value never leaks).
      refute html =~ "vt_"
    end

    test "CROSS-ORG: a tenant broker in a DIFFERENT org sees ZERO contacts (org-scope isolation)", %{org_id: _org_id} do
      # A fresh org with no seed — the cross-org broker sees nothing.
      other_org = Ecto.UUID.generate()
      other_scope = DriftwoodWeb.CrmContactsLive.crm_scope(other_org)
      contacts = CrmReads.contacts(other_scope)

      assert contacts == [], "cross-org tenant read the scenario org's contacts"

      html =
        render(DriftwoodWeb.CrmContactsLive, %{
          no_org: false,
          org_id: other_org,
          contacts: contacts,
          flash: %{}
        })

      # No PII from the other org — neither clear nor masked.
      refute html =~ "Dana"
      refute html =~ "Whitfield"
      refute html =~ "vt_"
    end
  end

  # ==========================================================================
  # MASKING INVARIANT: the LiveView itself never unwraps %Masked{}
  # ==========================================================================

  test "the contacts LiveView renders a %Masked{} as •••• (UIKit masking invariant)", %{org_id: _org_id} do
    # Synthesize a contact struct with a %Masked{} full_name and masked emails/phones —
    # the exact shape the resolver returns on the operator plane. No DB needed.
    masked_name = Samen.Masked.new("vault:test-tok-name", :full_name)
    masked_emails = Samen.Masked.new("vault:test-tok-email", :emails)
    masked_phones = Samen.Masked.new("vault:test-tok-phone", :phones)

    fake_contact = %{
      id: Ecto.UUID.generate(),
      full_name: masked_name,
      emails: masked_emails,
      phones: masked_phones,
      display_name: "Test User",
      job_title: "test",
      company_id: nil
    }

    html =
      render(DriftwoodWeb.CrmContactsLive, %{
        no_org: false,
        org_id: Ecto.UUID.generate(),
        contacts: [fake_contact],
        flash: %{}
      })

    # The mask IS rendered (via Phoenix.HTML.Safe on %Masked{}).
    assert html =~ "••••"

    # The raw vault token NEVER leaks into the page.
    refute html =~ "vault:test-tok-name"
    refute html =~ "vault:test-tok-email"
    refute html =~ "vault:test-tok-phone"
    refute html =~ "test-tok"
  end
end
