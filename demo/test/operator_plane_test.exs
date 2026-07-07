defmodule Demo.OperatorPlaneTest do
  @moduledoc """
  T4.1 clause (a): the operator plane built FROM THE SAME scope objects — an operator
  CRM where accounts ARE tenant orgs (Identity Org joined to Billing Subscription/Plan),
  operator ticketing over Support tickets, single-org billing summary.

  Single-org paths only (cross-tenant aggregates are T4.2). Operator actors are a
  DISTINCT actor type with their own RBAC (`Samen.OperatorPlane.Actor`), NOT tenant
  members.

  Red path: a `:operator_readonly` may READ the operator CRM but may NOT impersonate; a
  non-operator actor may do neither.
  """
  use Demo.DataCase, async: false

  alias Samen.OperatorPlane
  alias Samen.OperatorPlane.Actor

  defp mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_plan(org_id, name) do
    {:ok, plan} =
      Demo.BillingScope.Plan
      |> Ash.Changeset.for_create(:create, %{name: name, org_id: org_id})
      |> Ash.create(authorize?: false)

    plan
  end

  defp mk_customer(org_id) do
    {:ok, cust} =
      Demo.BillingScope.Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        billing_name: %{first: "Bill", last: "Payer"},
        billing_email: "billing@example.com"
      })
      |> Ash.create(authorize?: false)

    cust
  end

  defp mk_subscription(org_id, customer_id, plan_id) do
    {:ok, sub} =
      Demo.BillingScope.Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        customer_id: customer_id,
        plan_id: plan_id,
        status: :active
      })
      |> Ash.create(authorize?: false)

    sub
  end

  defp mk_ticket(org_id, status) do
    {:ok, t} =
      Demo.SupportScope.Ticket
      |> Ash.Changeset.for_create(:create, %{
        subject: "Ticket #{System.unique_integer([:positive])}",
        status: status,
        priority: :normal,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    t
  end

  test "the operator CRM account view: account IS the tenant org (Identity + Billing join + ticket rollup)" do
    org = mk_org("Acme Corp")
    plan = mk_plan(org.id, "Pro")
    cust = mk_customer(org.id)
    _sub = mk_subscription(org.id, cust.id, plan.id)
    _t1 = mk_ticket(org.id, :open)
    _t2 = mk_ticket(org.id, :open)
    _t3 = mk_ticket(org.id, :closed)

    op = Actor.new("op-crm-1", :operator_support)

    assert {:ok, account} = OperatorPlane.account(op, org.id)
    assert account.org_id == org.id
    # Account IS the tenant org — its name is the operator-visible non-PII fact.
    assert account.org_name == "Acme Corp"
    # Billing subscription join.
    assert account.subscription.status == :active
    assert account.subscription.plan == "Pro"
    # Single-org ticket rollup.
    assert account.open_tickets == 2
    assert account.total_tickets == 3
  end

  test "operator ticketing over ONE org's tickets (single-org)" do
    org = mk_org("Acme")
    _t1 = mk_ticket(org.id, :open)
    _t2 = mk_ticket(org.id, :open)

    other = mk_org("Other")
    _o1 = mk_ticket(other.id, :open)

    op = Actor.new("op-tick-1", :operator_admin)
    assert {:ok, tickets} = OperatorPlane.tickets(op, org.id)
    assert length(tickets) == 2
    assert Enum.all?(tickets, &(&1.status == :open))
  end

  test "the account view carries NO tenant-customer PII (only the org's own facts)" do
    org = mk_org("Acme")
    plan = mk_plan(org.id, "Pro")
    cust = mk_customer(org.id)
    _sub = mk_subscription(org.id, cust.id, plan.id)

    op = Actor.new("op-crm-2", :operator_support)
    {:ok, account} = OperatorPlane.account(op, org.id)

    # The billing summary is subscription status + plan name — NOT the customer's
    # vaulted billing_name/billing_email. No PII in the operator CRM account view.
    refute inspect(account) =~ "billing@example.com"
    refute inspect(account) =~ "Bill"
  end

  # =========================================================================
  # RED PATH: operator RBAC
  # =========================================================================

  test "RED PATH: :operator_readonly may read the operator CRM but may NOT impersonate" do
    org = mk_org("Acme")
    ro = Actor.new("op-ro", :operator_readonly)

    # May read the operator CRM.
    assert {:ok, _account} = OperatorPlane.account(ro, org.id)
    assert OperatorPlane.may_read_operator_crm?(ro)

    # May NOT impersonate.
    refute Actor.may_impersonate?(ro)
    assert {:error, :not_authorized} = Samen.Impersonation.open(ro, org.id, "reason")
  end

  test "RED PATH: a non-operator actor may not read the operator CRM" do
    org = mk_org("Acme")
    refute OperatorPlane.may_read_operator_crm?(%{id: "tenant-user", role: :admin})
    assert {:error, :not_authorized} = OperatorPlane.account(%{id: "tenant-user"}, org.id)
  end
end
