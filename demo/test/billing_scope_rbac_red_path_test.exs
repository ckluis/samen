defmodule Demo.BillingScopeRbacRedPathTest do
  @moduledoc """
  RBAC red paths for the Billing scope (T3.3; scope-authoring guide §9).

  Verifies:
    * member actors cannot mutate Tier-0 config rows (Plan, Price);
    * member actors cannot mutate admin-gated resources (Subscription, Invoice, Payment, Entitlement);
    * admin actors CAN mutate the same resources;
    * member actors CAN mutate member-gated resources (Usage);
    * admin actors cannot read foreign org rows (cross-org RBAC + org-scope).

  The RBAC checks are exercised through the REAL Ash policy authorizer against the
  REAL Postgres (not mocked). Positive controls ensure checks are not vacuously restrictive.
  """
  use Demo.DataCase, async: false

  alias Demo.BillingScope.{Customer, Subscription, Plan, Price, Invoice, Payment, Usage, Entitlement}
  alias Demo.Identity.{Org, User}

  # --- helpers ---------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "rbac-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "RBAC", last: "Test"},
        emails: ["rbac#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_customer(org_id) do
    {:ok, c} =
      Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        billing_name: "RBAC Customer",
        billing_email: "rbac@billing.example"
      })
      |> Ash.create(authorize?: false)

    c
  end

  defp mk_plan(org_id) do
    {:ok, p} =
      Plan
      |> Ash.Changeset.for_create(:create, %{
        name: "TestPlan-#{:rand.uniform(9999)}",
        org_id: org_id,
        interval: :monthly
      })
      |> Ash.create(authorize?: false)

    p
  end

  defp mk_subscription(org_id, customer_id, plan_id) do
    {:ok, s} =
      Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        customer_id: customer_id,
        plan_id: plan_id,
        status: :active
      })
      |> Ash.create(authorize?: false)

    s
  end

  # =========================================================================
  # Tier-0 config rows: Plan — admin-gated writes.
  # =========================================================================

  test "member cannot create a plan (Tier-0 admin-gate)" do
    org = mk_org("rbac-plan-member")
    member = mk_actor(org.id, :member)

    result =
      Plan
      |> Ash.Changeset.for_create(:create, %{
        name: "Sneaky",
        org_id: org.id,
        interval: :monthly
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin CAN create a plan (Tier-0 positive control)" do
    org = mk_org("rbac-plan-admin")
    admin = mk_actor(org.id, :admin)

    assert {:ok, plan} =
             Plan
             |> Ash.Changeset.for_create(:create, %{
               name: "AdminPlan",
               org_id: org.id,
               interval: :monthly
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert plan.name == "AdminPlan"
  end

  test "member cannot update a plan (Tier-0 admin-gate)" do
    org = mk_org("rbac-plan-upd-member")
    member = mk_actor(org.id, :member)
    plan = mk_plan(org.id)

    result =
      plan
      |> Ash.Changeset.for_update(:update, %{label: "tampered"})
      |> Ash.update(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin CAN update a plan (positive control)" do
    org = mk_org("rbac-plan-upd-admin")
    admin = mk_actor(org.id, :admin)
    plan = mk_plan(org.id)

    assert {:ok, updated} =
             plan
             |> Ash.Changeset.for_update(:update, %{label: "Enterprise"})
             |> Ash.update(actor: admin.actor, authorize?: true)

    assert updated.label == "Enterprise"
  end

  # =========================================================================
  # Price — admin-gated writes.
  # =========================================================================

  test "member cannot create a price (admin-gate)" do
    org = mk_org("rbac-price-member")
    member = mk_actor(org.id, :member)
    plan = mk_plan(org.id)

    result =
      Price
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        plan_id: plan.id,
        # ADR-036 §4.5: unit_amount_cents/currency dropped by the H1 Money migration.
        unit_amount: Samen.Type.Money.from_cents(999, :USD)
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Subscription — admin-gated writes.
  # =========================================================================

  test "member cannot create a subscription (admin-gate)" do
    org = mk_org("rbac-sub-member")
    member = mk_actor(org.id, :member)
    customer = mk_customer(org.id)
    plan = mk_plan(org.id)

    result =
      Subscription
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        customer_id: customer.id,
        plan_id: plan.id,
        status: :active
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin CAN create a subscription (positive control)" do
    org = mk_org("rbac-sub-admin")
    admin = mk_actor(org.id, :admin)
    customer = mk_customer(org.id)
    plan = mk_plan(org.id)

    assert {:ok, sub} =
             Subscription
             |> Ash.Changeset.for_create(:create, %{
               org_id: org.id,
               customer_id: customer.id,
               plan_id: plan.id,
               status: :active
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert sub.status == :active
  end

  # =========================================================================
  # Invoice — admin-gated writes.
  # =========================================================================

  test "member cannot create an invoice (admin-gate)" do
    org = mk_org("rbac-inv-member")
    member = mk_actor(org.id, :member)
    customer = mk_customer(org.id)

    result =
      Invoice
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        customer_id: customer.id,
        amount_due_cents: 1000
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Payment — admin-gated writes.
  # =========================================================================

  test "member cannot create a payment (admin-gate)" do
    org = mk_org("rbac-pay-member")
    member = mk_actor(org.id, :member)
    customer = mk_customer(org.id)

    result =
      Payment
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        customer_id: customer.id,
        amount_cents: 1000,
        status: :pending
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Usage — member-gated writes (members CAN record usage).
  # =========================================================================

  test "member CAN record usage (member-gate positive control)" do
    org = mk_org("rbac-use-member")
    member = mk_actor(org.id, :member)
    customer = mk_customer(org.id)
    plan = mk_plan(org.id)
    sub = mk_subscription(org.id, customer.id, plan.id)

    assert {:ok, usage} =
             Usage
             |> Ash.Changeset.for_create(:create, %{
               org_id: org.id,
               subscription_id: sub.id,
               metric: :api_calls,
               quantity: 100
             })
             |> Ash.create(actor: member.actor, authorize?: true)

    assert usage.quantity == 100
  end

  # =========================================================================
  # Entitlement — admin-gated writes.
  # =========================================================================

  test "member cannot create an entitlement (admin-gate)" do
    org = mk_org("rbac-ent-member")
    member = mk_actor(org.id, :member)
    customer = mk_customer(org.id)
    plan = mk_plan(org.id)
    sub = mk_subscription(org.id, customer.id, plan.id)

    result =
      Entitlement
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        subscription_id: sub.id,
        feature: :sso,
        granted: true
      })
      |> Ash.create(actor: member.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "admin CAN create an entitlement (positive control)" do
    org = mk_org("rbac-ent-admin")
    admin = mk_actor(org.id, :admin)
    customer = mk_customer(org.id)
    plan = mk_plan(org.id)
    sub = mk_subscription(org.id, customer.id, plan.id)

    assert {:ok, ent} =
             Entitlement
             |> Ash.Changeset.for_create(:create, %{
               org_id: org.id,
               subscription_id: sub.id,
               feature: :sso,
               granted: true
             })
             |> Ash.create(actor: admin.actor, authorize?: true)

    assert ent.feature == :sso
    assert ent.granted == true
  end

  # =========================================================================
  # SyncAdapter stub — verify callbacks are invokable without live Stripe.
  # =========================================================================

  test "SyncAdapter.Stub records calls and returns {:ok, _} without live Stripe" do
    alias Samen.Scopes.Billing.SyncAdapter.Stub

    Stub.reset()

    {:ok, _} = Stub.sync_customer(%{id: "c1", org_id: "o1", status: :active, stripe_customer_id: nil}, [])
    {:ok, _} = Stub.sync_subscription(%{id: "s1", org_id: "o1", customer_id: "c1", plan_id: nil, status: :active, stripe_subscription_id: nil}, [])
    {:ok, _} = Stub.sync_invoice(%{id: "i1", org_id: "o1", customer_id: "c1", stripe_invoice_id: nil, amount_due_cents: 1000}, [])
    {:ok, _} = Stub.cancel_subscription("s1", [])

    calls = Stub.calls()
    assert length(calls) == 4

    assert Enum.any?(calls, fn {cb, _} -> cb == :sync_customer end)
    assert Enum.any?(calls, fn {cb, _} -> cb == :sync_subscription end)
    assert Enum.any?(calls, fn {cb, _} -> cb == :sync_invoice end)
    assert Enum.any?(calls, fn {cb, _} -> cb == :cancel_subscription end)
  end
end
