defmodule Samen.Web.OperatorDeskRenderTest do
  @moduledoc """
  Framework OPERATOR / Desk render tests (ADR-010 §4c). Proves the SaaS help desk: tickets
  TENANTS file WITH the SaaS, requester = a tenant-admin (PII CLEAR), SLA/priority, and the
  handling SaaS support agent.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  setup do
    seed = OpSeeds.seed_all(tenants: 2)
    %{seed: seed}
  end

  test "/operator/desk renders the tenant-filed tickets", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.DeskLive, mount, [])

    assert html =~ ~s(class="app")
    assert html =~ "desk-ticket-row"
    assert html =~ "Cannot invite a second admin"
    assert html =~ "Invoice PDF export failing"
  end

  test "requester = a tenant-admin, PII CLEAR (the SaaS's own customer)", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.DeskLive, mount, [])

    # The requester's name + email render in the clear — the SaaS owns this contact.
    assert html =~ OpSeeds.admin_full_name()
    assert html =~ OpSeeds.admin_email()
    refute html =~ "••••"
  end

  test "assignment: the handling SaaS support agent is joined (PII CLEAR — the SaaS's employee)", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.DeskLive, mount, [])

    assert html =~ "t-agent"
    assert html =~ OpSeeds.agent_full_name()
  end

  test "SLA + priority ride the ticket columns", %{seed: seed} do
    mount = build_operator_mount(seed.operator_org_id)
    html = render_live(Samen.Web.Operator.DeskLive, mount, [])

    # The high-priority ticket renders a priority pill; the SLA/status column is present.
    assert html =~ "t-priority"
    assert html =~ "high"
    assert html =~ "t-sla"
  end
end
