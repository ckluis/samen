defmodule Demo.AggregatePlaneTest do
  @moduledoc """
  T4.2 — the token-blind aggregate plane, end-to-end on the demo (clauses (a)-(d)).

  Proves, against a real Postgres DB with seeded cross-tenant Billing + Support data:

    * (c)+(d) The cross-tenant operator dashboard (`Demo.OperatorDashboard`) reads
      MRR and queue depths ONLY through the token-blind aggregate domain
      (`Demo.Aggregate`) with the singleton aggregate actor, over the vault-excluded
      `amr_*` / `atq_*` projections. Cross-tenant totals span multiple orgs.

    * RED (mutual exclusion, tenant→aggregate): a TENANT actor reading the aggregate
      domain is DENIED (zero rows) — `AggregateActorOnly` is default-deny.

    * RED (mutual exclusion, aggregate→tenant): the aggregate actor reading a
      tenant-plane resource is DENIED (zero rows) — the org-less actor hits
      OrgScope's fail-closed filter.

    * The projection tables physically contain NO `pii_` columns (information_schema),
      and the whole-app `mix samen.verify.no_pii_columns` backstop passes.

  Anti-tautology: the aggregate actor DOES read the aggregate domain (positive
  control) and a tenant actor DOES read its own tenant rows (positive control) — so
  the denials are the mutual-exclusion boundary, not an always-deny.
  """
  use Demo.DataCase, async: false

  alias Demo.Aggregate.{MrrByTier, TicketQueueDepth}
  alias Demo.OperatorDashboard
  alias Samen.Aggregate.Actor

  # --- seeding helpers (mirror Demo.OperatorPlaneTest) ---------------------

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

  defp mk_price(org_id, plan_id, cents) do
    {:ok, price} =
      Demo.BillingScope.Price
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        plan_id: plan_id,
        unit_amount_cents: cents,
        active: true
      })
      |> Ash.create(authorize?: false)

    price
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

  defp mk_ticket(org_id, status, priority) do
    {:ok, t} =
      Demo.SupportScope.Ticket
      |> Ash.Changeset.for_create(:create, %{
        subject: "Ticket #{System.unique_integer([:positive])}",
        status: status,
        priority: priority,
        org_id: org_id
      })
      |> Ash.create(authorize?: false)

    t
  end

  # Seed two tenants on the SAME "Pro" tier (a cross-tenant aggregate), plus tickets.
  #
  # T4.5: the demo floor is k=2 / l=2 (demo config). To clear BOTH floors the `open`
  # cohort must be >= 2 tickets (k-anon) AND span >= 2 distinct priorities (l-div).
  # The `closed` cohort is deliberately a single ticket (a count-of-one that MUST
  # suppress under k-anon — the load-bearing guarantee).
  defp seed_cross_tenant! do
    org_a = mk_org("Acme")
    org_b = mk_org("Globex")

    # Both on a "Pro" plan priced at 5000 cents/mo (tenant_count = 2 >= k).
    plan_a = mk_plan(org_a.id, "Pro")
    plan_b = mk_plan(org_b.id, "Pro")
    mk_price(org_a.id, plan_a.id, 5000)
    mk_price(org_b.id, plan_b.id, 5000)

    cust_a = mk_customer(org_a.id)
    cust_b = mk_customer(org_b.id)
    mk_subscription(org_a.id, cust_a.id, plan_a.id)
    mk_subscription(org_b.id, cust_b.id, plan_b.id)

    # `open` cohort: 3 tickets across both tenants, spanning 2 distinct priorities
    # (normal + high) → clears k=2 and l=2. `closed` cohort: 1 ticket → count-of-one,
    # suppresses under k-anon.
    mk_ticket(org_a.id, :open, :normal)
    mk_ticket(org_a.id, :open, :high)
    mk_ticket(org_b.id, :open, :normal)
    mk_ticket(org_b.id, :closed, :normal)

    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)
    %{org_a: org_a, org_b: org_b}
  end

  # =========================================================================
  # (c)+(d): the cross-tenant dashboard reads ONLY through the aggregate domain
  # =========================================================================

  test "cross-tenant MRR: the operator dashboard reads MRR by tier across ALL tenants through the aggregate domain" do
    seed_cross_tenant!()

    assert {:ok, %{total_cents: total, by_tier: by_tier}} = OperatorDashboard.mrr()

    # Two tenants, both Pro @ 5000 cents = 10000 cents total, 2 tenants on the tier.
    pro = Enum.find(by_tier, &(&1.tier == "Pro"))
    assert pro.tenant_count == 2
    assert pro.mrr_cents == 10_000
    assert total == 10_000
  end

  test "cross-tenant queue depth: the operator dashboard reads support-queue depth by status across ALL tenants (T4.5 floors applied)" do
    seed_cross_tenant!()

    assert {:ok, depths} = OperatorDashboard.queue_depths()
    by_status = Map.new(depths, &{&1.status, &1.depth})

    # `open` clears both floors (depth 3 >= k=2; 2 distinct priorities >= l=2) → released.
    assert by_status["open"] == 3

    # `closed` is a count-of-one cohort (depth 1 < k=2) → SUPPRESSED under k-anonymity.
    # The dashboard NEVER returns the raw `1` (which would re-identify the single ticket's
    # tenant/subject); it returns the fail-closed sentinel.
    assert %Samen.Aggregate.Suppressed{reason: :k_anonymity} = by_status["closed"]
  end

  test "control (anti-tautology): the AGGREGATE ACTOR reads the aggregate domain (positive control for the denials below)" do
    seed_cross_tenant!()

    assert {:ok, rows} = Samen.Aggregate.read_all(MrrByTier)
    assert rows != []
    assert Enum.all?(rows, &Map.has_key?(&1, :tier))
    # No PII field is even present on the projection (structurally token-blind).
    refute Enum.any?(rows, fn r -> Map.has_key?(r, :full_name) or Map.has_key?(r, :emails) end)
  end

  # =========================================================================
  # RED: mutual exclusion — a TENANT actor reading the aggregate domain denies
  # =========================================================================

  test "RED: a TENANT actor reading the aggregate domain is DENIED (default-deny AggregateActorOnly)" do
    seed_cross_tenant!()

    tenant_actor = %{id: "tenant-user", org_id: Ash.UUID.generate(), role: :admin}

    # Reading the aggregate resource as a tenant actor returns ZERO rows (the
    # default-deny policy forbids; a FilterCheck-free forbid → empty/forbidden).
    result = Ash.read(MrrByTier, actor: tenant_actor, authorize?: true)

    case result do
      {:ok, rows} -> assert rows == []
      {:error, _forbidden} -> assert true
    end
  end

  test "RED: an operator-plane (impersonation) actor reading the aggregate domain is DENIED" do
    seed_cross_tenant!()

    # The impersonation actor is kind: :operator — NOT :operator_aggregate. The two
    # operator paths are mutually exclusive: it cannot read the aggregate domain.
    op_actor = %{id: "op-1", kind: :operator}
    result = Ash.read(TicketQueueDepth, actor: op_actor, authorize?: true)

    case result do
      {:ok, rows} -> assert rows == []
      {:error, _forbidden} -> assert true
    end
  end

  # =========================================================================
  # RED: mutual exclusion — the aggregate actor reading a tenant-plane resource denies
  # =========================================================================

  test "RED: the AGGREGATE ACTOR reading a tenant-plane resource is DENIED (org-less → OrgScope fail-closed)" do
    %{org_a: org_a} = seed_cross_tenant!()

    agg = Actor.new()

    # The aggregate actor has no org_id. A tenant-plane resource with an OrgScope
    # read policy filters it to ZERO rows. Demo.Crm.Contact is org-scoped on reads.
    {:ok, contact} =
      Demo.Crm.Contact
      |> Ash.Changeset.for_create(:create, %{
        display_name: "Someone",
        org_id: org_a.id,
        full_name: %{first: "Se", last: "Cret"},
        emails: ["secret@acme.com"]
      })
      |> Ash.create(authorize?: false)

    assert contact.id

    # As the org-less aggregate actor: DENIED. OrgScope's FilterCheck for a nil-org
    # actor is `expr(false)` — no scenario authorizes, so Ash returns Forbidden (a
    # stronger deny than an empty set; either is a valid fail-closed outcome). The
    # aggregate actor can never see a single tenant row.
    result = Ash.read(Demo.Crm.Contact, actor: agg, authorize?: true)

    case result do
      {:ok, rows} -> assert rows == []
      {:error, %Ash.Error.Forbidden{}} -> assert true
    end
  end

  test "control (anti-tautology): a TENANT actor WITH the right org DOES read its own tenant rows" do
    %{org_a: org_a} = seed_cross_tenant!()

    {:ok, _contact} =
      Demo.Crm.Contact
      |> Ash.Changeset.for_create(:create, %{
        display_name: "Visible",
        org_id: org_a.id,
        full_name: %{first: "Vi", last: "Sible"},
        emails: ["vi@acme.com"]
      })
      |> Ash.create(authorize?: false)

    tenant_actor = %{id: "u1", org_id: org_a.id, role: :admin}
    assert {:ok, rows} = Ash.read(Demo.Crm.Contact, actor: tenant_actor, authorize?: true)
    # The tenant actor sees its own org's row — proving the aggregate-actor denial
    # above is the org-less boundary, not an always-deny.
    assert Enum.any?(rows, &(&1.display_name == "Visible"))
  end

  # =========================================================================
  # (b)/(c): the projection tables physically contain NO pii_ columns
  # =========================================================================

  test "the aggregate projection tables physically contain NO pii_ columns (information_schema)" do
    for table <- ["amr_mrr_by_tier", "atq_ticket_queue_depth"] do
      %{rows: rows} =
        Demo.Repo.query!(
          """
          SELECT column_name
          FROM information_schema.columns
          WHERE table_name = $1 AND column_name LIKE 'pii_%'
          """,
          [table]
        )

      assert rows == [],
             "aggregate projection #{table} must have NO pii_ columns, found: #{inspect(rows)}"
    end
  end

  test "the whole-app C7 backstop finds no violations on the aggregate domain" do
    # DSL sweep (re-run C7 rules on the compiled aggregate resources).
    assert Mix.Tasks.Samen.Verify.NoPiiColumns.dsl_violations(domain: "Demo.Aggregate") == []

    # information_schema sweep against the live projection tables.
    assert Mix.Tasks.Samen.Verify.NoPiiColumns.physical_column_violations(
             domain: "Demo.Aggregate",
             repo: "Demo.Repo"
           ) == []

    # And the aggregate resources ARE discovered as aggregate-plane.
    resources = Mix.Tasks.Samen.Verify.NoPiiColumns.aggregate_resources(domain: "Demo.Aggregate")
    assert MrrByTier in resources
    assert TicketQueueDepth in resources
  end
end
