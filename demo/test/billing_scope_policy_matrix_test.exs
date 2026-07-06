defmodule Demo.BillingScopePolicyMatrixTest do
  @moduledoc """
  The Billing scope org-scope + RBAC policy matrix (T3.3). Exercises the REAL
  mounted Billing resources against the REAL Postgres, through the REAL Ash policy
  authorizer.

  Covers:
    * cross-org read denied (org-scope FilterCheck) — a property test over many
      org pairs (the `cross-org read denied` red path);
    * cross-org write denied;
    * PII masked-by-default on the tenant-plane read (customer🔒);
    * positive cases (an actor sees + writes its OWN org's rows);
    * Tier-0 config rows (plan, price) — admin-gate enforced;
    * entitlement check helper — entitled?/4 returns correct results.
  """
  use Demo.DataCase, async: false
  use ExUnitProperties

  alias Demo.BillingScope.{Customer, Subscription, Plan, Price, Invoice, Payment, Usage, Entitlement}
  alias Demo.Identity.{Org, User}

  # --- helpers ---------------------------------------------------------------

  defp mk_org(name) do
    {:ok, org} =
      Org
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(authorize?: false)

    org
  end

  defp mk_actor(org_id, role \\ :member) do
    {:ok, user} =
      User
      |> Ash.Changeset.for_create(:create, %{
        handle: "billing-actor-#{:rand.uniform(999_999)}",
        org_id: org_id,
        full_name: %{first: "Billing", last: "Actor"},
        emails: ["billing#{:rand.uniform(999_999)}@example.com"]
      })
      |> Ash.create(authorize?: false)

    Samen.Scope.new(%{id: user.id, org_id: org_id, role: role})
  end

  defp mk_customer(org_id) do
    {:ok, c} =
      Customer
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        billing_name: "Test Customer",
        billing_email: "customer@example.com",
        status: :active
      })
      |> Ash.create(authorize?: false)

    c
  end

  defp mk_plan(org_id, name \\ "Free") do
    {:ok, p} =
      Plan
      |> Ash.Changeset.for_create(:create, %{
        name: name,
        org_id: org_id,
        interval: :monthly,
        enabled: true,
        features: %{"basic" => true}
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
  # Cross-org read denial — the org-scope FilterCheck. PROPERTY test.
  # =========================================================================

  property "an actor scoped to org A never reads another org's customers (cross-org read denied)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 8),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 8),
            max_runs: 20
          ) do
      org_a = mk_org("bill-A-" <> name_a)
      org_b = mk_org("bill-B-" <> name_b)

      scope_a = mk_actor(org_a.id)
      mk_customer(org_b.id)

      query = Customer |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      # Org B's customer is invisible (filtered, not just forbidden).
      refute org_b.id in seen_orgs
    end
  end

  property "an actor scoped to org A never reads another org's subscriptions (cross-org)" do
    check all(
            name_a <- string(:alphanumeric, min_length: 1, max_length: 6),
            name_b <- string(:alphanumeric, min_length: 1, max_length: 6),
            max_runs: 20
          ) do
      org_a = mk_org("subA-" <> name_a)
      org_b = mk_org("subB-" <> name_b)

      scope_a = mk_actor(org_a.id)
      cust_b = mk_customer(org_b.id)
      plan_b = mk_plan(org_b.id)
      mk_subscription(org_b.id, cust_b.id, plan_b.id)

      query = Subscription |> Ash.Query.select([:id, :org_id])
      {:ok, seen} = Ash.read(query, actor: scope_a.actor, authorize?: true)
      seen_orgs = seen |> Enum.map(& &1.org_id) |> Enum.uniq()

      refute org_b.id in seen_orgs
    end
  end

  # =========================================================================
  # Cross-org WRITE denial.
  # =========================================================================

  test "an actor cannot update a foreign org's customer (cross-org write denied)" do
    org_a = mk_org("wba-cust")
    org_b = mk_org("wbb-cust")

    scope_a = mk_actor(org_a.id, :admin)
    customer_b = mk_customer(org_b.id)

    result =
      customer_b
      |> Ash.Changeset.for_update(:update, %{currency: "GBP"})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "an actor cannot update a foreign org's plan (cross-org write denied)" do
    org_a = mk_org("wba-plan")
    org_b = mk_org("wbb-plan")

    scope_a = mk_actor(org_a.id, :admin)
    plan_b = mk_plan(org_b.id, "PlanB")

    result =
      plan_b
      |> Ash.Changeset.for_update(:update, %{label: "tampered"})
      |> Ash.update(actor: scope_a.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  # =========================================================================
  # Org-less actor — fail closed.
  # =========================================================================

  test "an org-less actor sees zero billing rows (fail closed)" do
    org = mk_org("orgless-billing")
    mk_customer(org.id)

    orgless_actor = %{id: "nobody", org_id: nil, role: :member}

    case Ash.read(Customer, actor: orgless_actor, authorize?: true) do
      {:ok, seen} -> assert seen == []
      {:error, %Ash.Error.Forbidden{}} -> assert true
    end
  end

  # =========================================================================
  # Positive cases — an actor DOES see + write its OWN org's rows.
  # =========================================================================

  test "an actor sees its own org's customer (positive read case)" do
    org = mk_org("self-read-cust")
    scope = mk_actor(org.id, :admin)
    mk_customer(org.id)

    query = Customer |> Ash.Query.select([:id, :org_id])
    {:ok, seen} = Ash.read(query, actor: scope.actor, authorize?: true)
    assert length(seen) == 1
    assert hd(seen).org_id == org.id
  end

  test "an admin actor CAN create a plan (Tier-0 config row)" do
    org = mk_org("admin-plan")
    admin_scope = mk_actor(org.id, :admin)

    assert {:ok, plan} =
             Plan
             |> Ash.Changeset.for_create(:create, %{
               name: "Pro",
               org_id: org.id,
               interval: :monthly,
               enabled: true
             })
             |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert plan.name == "Pro"
    assert plan.interval == :monthly
  end

  # =========================================================================
  # Tier-0 config rows: Plan and Price — admin-gated writes.
  # =========================================================================

  test "a member actor cannot create a plan (admin-gate enforced)" do
    org = mk_org("member-plan-gate")
    member_scope = mk_actor(org.id, :member)

    result =
      Plan
      |> Ash.Changeset.for_create(:create, %{name: "Sneaky", org_id: org.id, interval: :monthly})
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result
  end

  test "a member actor cannot create a price (admin-gate enforced)" do
    org = mk_org("member-price-gate")
    admin_scope = mk_actor(org.id, :admin)
    member_scope = mk_actor(org.id, :member)
    plan = mk_plan(org.id)

    result =
      Price
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        plan_id: plan.id,
        unit_amount_cents: 2900,
        currency: "USD",
        interval: :monthly
      })
      |> Ash.create(actor: member_scope.actor, authorize?: true)

    assert {:error, %Ash.Error.Forbidden{}} = result

    # Admin can create a price.
    assert {:ok, price} =
             Price
             |> Ash.Changeset.for_create(:create, %{
               org_id: org.id,
               plan_id: plan.id,
               unit_amount_cents: 2900,
               currency: "USD",
               interval: :monthly
             })
             |> Ash.create(actor: admin_scope.actor, authorize?: true)

    assert price.unit_amount_cents == 2900
    _ = member_scope
  end

  # =========================================================================
  # PII masked-by-default on the tenant-plane read (customer🔒).
  # =========================================================================

  test "customer PII (billing_name, billing_email) is %Masked{} by default on a tenant-plane read" do
    org = mk_org("mask-cust")
    scope = mk_actor(org.id, :member)
    mk_customer(org.id)

    query = Customer |> Ash.Query.select([:id, :billing_name, :billing_email])
    {:ok, [customer]} = Ash.read(query, actor: scope.actor, authorize?: true)

    assert %Samen.Masked{} = customer.billing_name
    assert %Samen.Masked{} = customer.billing_email

    # The masked value renders as bullets.
    assert Phoenix.HTML.Safe.to_iodata(customer.billing_name) |> IO.iodata_to_binary() =~ "•"
    assert Phoenix.HTML.Safe.to_iodata(customer.billing_email) |> IO.iodata_to_binary() =~ "•"
  end

  # =========================================================================
  # Entitlement check helper.
  # =========================================================================

  test "entitled?/4 returns {:ok, true} for an org with an active entitlement" do
    org = mk_org("ent-check-true")
    customer = mk_customer(org.id)
    plan = mk_plan(org.id, "Pro")
    subscription = mk_subscription(org.id, customer.id, plan.id)

    # Create an entitlement row.
    {:ok, _ent} =
      Entitlement
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        subscription_id: subscription.id,
        plan_id: plan.id,
        feature: :advanced_reporting,
        granted: true
      })
      |> Ash.create(authorize?: false)

    result =
      Samen.Scopes.Billing.Entitlement.entitled_direct?(
        org.id,
        :advanced_reporting,
        "ben_entitlement",
        Demo.Repo
      )

    assert {:ok, true} = result
  end

  test "entitled?/4 returns {:ok, false} for an org without the entitlement" do
    org = mk_org("ent-check-false")

    result =
      Samen.Scopes.Billing.Entitlement.entitled_direct?(
        org.id,
        :sso,
        "ben_entitlement",
        Demo.Repo
      )

    assert {:ok, false} = result
  end

  test "entitled?/4 returns {:ok, false} for an expired entitlement" do
    org = mk_org("ent-check-expired")
    customer = mk_customer(org.id)
    plan = mk_plan(org.id)
    subscription = mk_subscription(org.id, customer.id, plan.id)

    # Create an expired entitlement.
    {:ok, _ent} =
      Entitlement
      |> Ash.Changeset.for_create(:create, %{
        org_id: org.id,
        subscription_id: subscription.id,
        feature: :api_access,
        granted: true,
        expires_at: ~U[2020-01-01 00:00:00Z]
      })
      |> Ash.create(authorize?: false)

    result =
      Samen.Scopes.Billing.Entitlement.entitled_direct?(
        org.id,
        :api_access,
        "ben_entitlement",
        Demo.Repo
      )

    assert {:ok, false} = result
  end

  # =========================================================================
  # Smoke: invoices, payments, usage are all org-scoped.
  # =========================================================================

  test "invoices, payments, usage are org-scoped (cross-org invisible)" do
    org_a = mk_org("smoke-ba")
    org_b = mk_org("smoke-bb")
    scope_a = mk_actor(org_a.id, :member)

    cust_b = mk_customer(org_b.id)
    plan_b = mk_plan(org_b.id)
    sub_b = mk_subscription(org_b.id, cust_b.id, plan_b.id)

    # Create invoice in org_b.
    {:ok, inv_b} =
      Invoice
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_b.id,
        customer_id: cust_b.id,
        subscription_id: sub_b.id,
        amount_due_cents: 2900,
        status: :open
      })
      |> Ash.create(authorize?: false)

    # Payment and usage in org_b.
    {:ok, _pay_b} =
      Payment
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_b.id,
        customer_id: cust_b.id,
        invoice_id: inv_b.id,
        amount_cents: 2900,
        status: :succeeded
      })
      |> Ash.create(authorize?: false)

    {:ok, _use_b} =
      Usage
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_b.id,
        subscription_id: sub_b.id,
        metric: :api_calls,
        quantity: 1000
      })
      |> Ash.create(authorize?: false)

    # org_a actor sees ZERO of org_b's rows across all resources.
    {:ok, invs} = Ash.read(Invoice, actor: scope_a.actor, authorize?: true)
    {:ok, pays} = Ash.read(Payment, actor: scope_a.actor, authorize?: true)
    {:ok, uses} = Ash.read(Usage, actor: scope_a.actor, authorize?: true)

    assert Enum.all?(invs, fn r -> r.org_id == org_a.id end)
    assert Enum.all?(pays, fn r -> r.org_id == org_a.id end)
    assert Enum.all?(uses, fn r -> r.org_id == org_a.id end)

    # Specifically, org_b's rows are absent.
    refute Enum.any?(invs, fn r -> r.id == inv_b.id end)
  end
end
