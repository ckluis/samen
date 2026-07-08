defmodule Samen.Web.OperatorIdentityLineTest do
  @moduledoc """
  THE IDENTITY LINE — the load-bearing test (ADR-010 §5.4). The operator seat governs TWO PII
  populations under OPPOSITE rules, and this test pins BOTH on the SAME seeded data:

    * **Population (1) — the SaaS's OWN book of business** (its tenant-org accounts + those
      accounts' tenant-ADMINS). CLEAR to the operator, because it is the operator org's OWN
      tenant plane (own-org PII, no reveal grant).
    * **Population (2) — a tenant's DOWNSTREAM end-customers**. `••••` to the operator, reachable
      only via impersonation (the ADR-009 `plane: :operator` path).

  The line is the COMPOSITION of two kernel primitives (`OrgScope` by org_id + `PiiResolution`
  by plane), separated ALSO by a mount boundary (operator namespace vs vertical namespace). No
  new masking code; this test proves the composition holds end-to-end.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Operator.Seeds, as: OpSeeds
  alias Samen.WebTest.Seeds, as: TenantSeeds

  setup do
    seed = OpSeeds.seed_all(tenants: 2)
    %{seed: seed}
  end

  # ==========================================================================
  # CLEAR SIDE (population 1): operator plane → tenant-admin PII in the clear
  # ==========================================================================

  test "CLEAR: the operator sees the tenant-ADMIN name/email in the clear (its own customer)", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.AccountsLive, mount, [])

    # The tenant-admin is the SaaS's OWN signup contact — clear by the tenant-plane resolver.
    assert html =~ OpSeeds.admin_full_name()
    assert html =~ OpSeeds.admin_email()
    # It is not masked on the operator's own book-of-business plane.
    refute html =~ "••••"
  end

  # ==========================================================================
  # MASKED SIDE (population 2): impersonation plane → tenant end-customer ••••
  # ==========================================================================

  test "MASKED: on the SAME session, a tenant END-customer is •••• (impersonation plane)", %{seed: seed} do
    # The account's downstream world is the real vertical-namespace tenant org (account 1).
    # "Open account" drills in via the ADR-009 operator/impersonation mount → PII masked.
    impersonation_mount =
      build_mount(:crm, plane: :operator, target_org_id: seed.tenant_org_id)

    html = render_live(Samen.Web.CRM.ContactsLive, impersonation_mount, [seed.tenant_org_id])

    # Non-vacuous: the tenant's downstream contact row is present (the operator opened it).
    assert html =~ "contact-row"
    # Population (2) MASKED: the tenant end-customer's PII does NOT render in the clear.
    assert html =~ "••••"
    refute html =~ TenantSeeds.contact_full_name()
    refute html =~ TenantSeeds.contact_email()
    refute html =~ TenantSeeds.contact_phone()
  end

  test "RED PATH: the impersonation render never leaks a vault token", %{seed: seed} do
    impersonation_mount =
      build_mount(:crm, plane: :operator, target_org_id: seed.tenant_org_id)

    html = render_live(Samen.Web.CRM.ContactsLive, impersonation_mount, [seed.tenant_org_id])

    refute html =~ "vt_"
    refute html =~ "pii_"
    refute html =~ TenantSeeds.contact_email()
  end

  # ==========================================================================
  # CROSS-LEAK RED PATH: the operator plane never surfaces a tenant end-customer
  # ==========================================================================

  test "CROSS-LEAK: the operator accounts view surfaces accounts, NEVER the tenant's downstream contacts", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.AccountsLive, mount, [])

    # The account (the tenant org) is present…
    assert html =~ "Blue Ridge Logistics 1"
    # …but the tenant's DOWNSTREAM end-customer (a different population, different namespace) is NOT.
    refute html =~ TenantSeeds.contact_full_name()
    refute html =~ TenantSeeds.contact_email()
  end

  test "CROSS-MOUNT REFUSAL: the operator-org actor reading the VERTICAL namespace returns zero rows", %{seed: seed} do
    # The operator-org tenant-plane actor (org_id = operator_org_id) reading the vertical
    # CRM namespace: OrgScope narrows to the operator org's rows, of which the vertical
    # namespace has NONE — the tenant end-customers belong to the tenant org, not the operator.
    scope = Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), seed.operator_org_id)

    people =
      Samen.WebTest.Crm.Person
      |> Ash.read!(scope: scope)

    assert people == []

    # And the tenant end-customer we seeded DOES exist (proving the empty result is a scope
    # refusal, not an empty DB): reading it on the tenant's OWN scope returns it.
    tenant_scope = Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), seed.tenant_org_id)
    tenant_people = Samen.WebTest.Crm.Person |> Ash.read!(scope: tenant_scope)
    assert length(tenant_people) >= 1
  end
end
