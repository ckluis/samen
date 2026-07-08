defmodule Driftwood.Seeds do
  @moduledoc """
  Tier-0 seeds for Driftwood (design §1(e), §6):

    * **Load-lifecycle stages** — Pipeline config rows (Quoted → Booked → Dispatched →
      In-Transit → Delivered → Invoiced). Tier-0: a broker reorders/renames stages
      without a fork.
    * **ELD providers** — the bounded `drv_eld_provider` enum
      (samsara/motive/geotab/other). Tier-0 config: enumerated here for the seed
      catalog and the UI dropdown; the CONSTRAINT is on the resource attribute.
    * **Load statuses** — the bounded `fop_status` set (open/won/lost/on_hold) reused
      from the kernel Opportunity; the freight-facing lifecycle lives on the Pipeline.

  `Driftwood.NonPiiSetup.register_all/0` is also called here so a fresh seed run has
  the reviewed non_pii! rows the pii_classify gate requires.
  """

  require Ash.Query

  @load_stages [
    %{name: "quoted", label: "Quoted", stage_order: 0, stage_type: "open"},
    %{name: "booked", label: "Booked", stage_order: 1, stage_type: "qualified"},
    %{name: "dispatched", label: "Dispatched", stage_order: 2, stage_type: "proposal"},
    %{name: "in_transit", label: "In Transit", stage_order: 3, stage_type: "proposal"},
    %{name: "delivered", label: "Delivered", stage_order: 4, stage_type: "won"},
    %{name: "invoiced", label: "Invoiced", stage_order: 5, stage_type: "won"}
  ]

  @eld_providers [:samsara, :motive, :geotab, :other]

  @doc "The Tier-0 ELD provider catalog (the bounded drv_eld_provider enum)."
  def eld_providers, do: @eld_providers

  @doc "The Tier-0 load-lifecycle stage catalog."
  def load_stages, do: @load_stages

  @doc """
  Seed the Tier-0 rows for `org_id`. Registers the non_pii! rows first, then seeds
  the load-lifecycle Pipeline stages. Returns `:ok`.
  """
  def run(org_id) do
    :ok = Driftwood.NonPiiSetup.register_all()

    actor = %{org_id: org_id, role: :admin}

    Enum.each(@load_stages, fn stage ->
      Driftwood.Crm.Pipeline
      |> Ash.Changeset.for_create(:create, Map.put(stage, :org_id, org_id),
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()
    end)

    :ok
  end

  # ==========================================================================
  # demo_all/1 — populate the INHERITED universal scopes (CRM · Billing · Support)
  # with freight-flavored data for the Blue Ridge Logistics tenant org, so the
  # inherited-module UI pages render REAL rows. Product thesis: "build the 20%
  # (freight), inherit the 80% (CRM/billing/support)".
  # ==========================================================================

  # The Blue Ridge Logistics tenant org gets a FIXED uuid so the dev one-liner and
  # the LiveView `?org=<uuid>` param agree without ceremony. (A real deploy derives
  # the tenant org from the authenticated session — see docs/driftwood-dogfood.md.)
  @blue_ridge_org_id "b1112d00-0000-4000-8000-000000000001"

  @doc "The FIXED Blue Ridge Logistics tenant org id the dev seed populates."
  def blue_ridge_org_id, do: @blue_ridge_org_id

  # ~8 CRM companies — carriers, shippers, and a factoring/broker partner.
  @companies [
    %{name: "Blue Ridge Carriers", role: "carrier"},
    %{name: "Summit Line Haul", role: "carrier"},
    %{name: "Cascade Freight Systems", role: "carrier"},
    %{name: "Ironwood Trucking", role: "carrier"},
    %{name: "Acme Manufacturing", role: "shipper"},
    %{name: "Harbor Foods Distribution", role: "shipper"},
    %{name: "Piedmont Steel Co", role: "shipper"},
    %{name: "Riverbend Paper Mills", role: "shipper"}
  ]

  # ~12 people — dispatchers, carrier reps, shipper AP contacts — each with
  # full_name/emails/phones so PII masking (tenant-clear vs operator-••••) is
  # demonstrable on the inherited CRM page.
  @people [
    {"Blue Ridge Carriers", "Dana", "Whitfield", "dispatcher", "dana.whitfield@blueridgecarriers.example", "+1-865-555-0142"},
    {"Blue Ridge Carriers", "Marcus", "Odell", "carrier rep", "marcus.odell@blueridgecarriers.example", "+1-865-555-0188"},
    {"Summit Line Haul", "Priya", "Nair", "dispatcher", "priya.nair@summitlinehaul.example", "+1-704-555-0117"},
    {"Summit Line Haul", "Cole", "Barrett", "carrier rep", "cole.barrett@summitlinehaul.example", "+1-704-555-0203"},
    {"Cascade Freight Systems", "Yuki", "Tanaka", "dispatcher", "yuki.tanaka@cascadefreight.example", "+1-503-555-0166"},
    {"Ironwood Trucking", "Rosa", "Delgado", "carrier rep", "rosa.delgado@ironwoodtrucking.example", "+1-615-555-0191"},
    {"Acme Manufacturing", "Ellis", "Grant", "shipper contact", "ellis.grant@acmemfg.example", "+1-214-555-0124"},
    {"Acme Manufacturing", "Nadia", "Osei", "AP clerk", "nadia.osei@acmemfg.example", "+1-214-555-0135"},
    {"Harbor Foods Distribution", "Tomas", "Vela", "shipper contact", "tomas.vela@harborfoods.example", "+1-206-555-0158"},
    {"Piedmont Steel Co", "Grace", "Lindqvist", "shipper contact", "grace.lindqvist@piedmontsteel.example", "+1-336-555-0172"},
    {"Riverbend Paper Mills", "Owen", "Fitzgerald", "AP clerk", "owen.fitzgerald@riverbendpaper.example", "+1-828-555-0149"},
    {"Riverbend Paper Mills", "Amara", "Boone", "shipper contact", "amara.boone@riverbendpaper.example", "+1-828-555-0153"}
  ]

  # ~6 opportunities (Loads) across the pipeline stages.
  @opportunities [
    {"BR-4471 Dallas -> Los Angeles dry van", 480_000, :open, "quoted"},
    {"BR-4472 Houston -> Sacramento reefer", 620_000, :open, "booked"},
    {"BR-4473 Atlanta -> Chicago dry van", 410_000, :open, "dispatched"},
    {"BR-4474 Charlotte -> Newark flatbed", 535_000, :open, "in_transit"},
    {"BR-4475 Memphis -> Denver reefer", 590_000, :won, "delivered"},
    {"BR-4476 Nashville -> Phoenix dry van", 445_000, :won, "invoiced"}
  ]

  # ~6 billing customers — the brokerage's shipper billing accounts, WITH
  # billing_name/billing_email PII (scalar-vaulted).
  @customers [
    {"Acme Manufacturing", "Acme Manufacturing Inc", "ap@acmemfg.example", :active},
    {"Harbor Foods Distribution", "Harbor Foods Distribution LLC", "billing@harborfoods.example", :active},
    {"Piedmont Steel Co", "Piedmont Steel Co", "accounts@piedmontsteel.example", :active},
    {"Riverbend Paper Mills", "Riverbend Paper Mills", "ap@riverbendpaper.example", :active},
    {"Summit Line Haul", "Summit Line Haul (carrier settlement)", "settlements@summitlinehaul.example", :active},
    {"Ironwood Trucking", "Ironwood Trucking (carrier settlement)", "pay@ironwoodtrucking.example", :inactive}
  ]

  # Billing plans (Tier-0 config): the brokerage's SaaS tiers.
  @plans [
    %{name: "starter", label: "Starter", price_cents: 9_900},
    %{name: "growth", label: "Growth", price_cents: 29_900},
    %{name: "scale", label: "Scale", price_cents: 79_900}
  ]

  # ~10 support tickets — freight disputes, across statuses/priorities.
  @tickets [
    {"Detention charge on load BR-4471", :open, :high},
    {"Missing BOL for BR-4473 delivery", :open, :urgent},
    {"Carrier no-show — Summit Line Haul BR-4472", :pending, :urgent},
    {"Reweigh dispute on BR-4474 flatbed", :pending, :normal},
    {"Lumper fee reimbursement BR-4475", :open, :normal},
    {"POD not received for BR-4476", :pending, :high},
    {"Overcharge on fuel surcharge BR-4471", :open, :normal},
    {"Damaged freight claim BR-4474", :on_hold, :high},
    {"Late delivery penalty inquiry BR-4472", :resolved, :low},
    {"Rate confirmation mismatch BR-4475", :resolved, :normal}
  ]

  # 2-3 support agents WITH PII (full_name composite + email scalar, both vaulted).
  @agents [
    {"claims-desk", "Sofia", "Marchetti", "sofia.marchetti@blueridgelogistics.example", :supervisor},
    {"dispatch-support", "Isaac", "Kowalski", "isaac.kowalski@blueridgelogistics.example", :agent},
    {"billing-support", "Leah", "Nakamura", "leah.nakamura@blueridgelogistics.example", :agent}
  ]

  @doc """
  Seed EVERYTHING for the inherited universal scopes (CRM · Billing · Support) for
  `org_id` (default: the Blue Ridge Logistics tenant). Populates the inherited-module
  UI pages with realistic freight-flavored data. Returns the `org_id`.

  Idempotent-ish: guarded by a marker read (an existing Support agent handle) so a
  re-run does not double-seed. The Tier-0 pipeline stages are seeded by
  `DogfoodScenario`/`run/1` and are NOT re-seeded here.

  Note: `demo_all/1` seeds the INHERITED-scope rows on top of whatever freight
  scenario already exists for the org. In dev, call `Driftwood.Seeds.dev_seed/0`
  (or `mix driftwood.seed`) which builds the freight fleet for the fixed org first,
  then layers these inherited rows on.
  """
  def demo_all(org_id \\ @blue_ridge_org_id) do
    :ok = Driftwood.NonPiiSetup.register_all()

    if seeded?(org_id) do
      org_id
    else
      :ok = define_custom_fields(org_id)

      companies = seed_companies(org_id)
      seed_people(org_id, companies)
      seed_opportunities(org_id, companies)

      {plans, customers} = seed_billing(org_id)
      seed_subscriptions_and_invoices(org_id, plans, customers)

      seed_support(org_id)

      org_id
    end
  end

  @doc """
  Full DEV seed for the fixed Blue Ridge Logistics org: builds the freight fleet
  (carriers/shippers/drivers/loads/dispatch/settlement + broker rollup) via
  `DogfoodScenario.build/1` on the fixed org, then layers the inherited-scope rows
  (`demo_all/1`) on top, then rebuilds the cross-tenant aggregate (seeding a SECOND
  org so the operator aggregate plane has >1 tenant/cohort). Returns the org id.

  Safe to re-run: the freight fleet + inherited rows are each guarded by a marker.
  """
  def dev_seed do
    org_id = @blue_ridge_org_id

    unless fleet_seeded?(org_id) do
      Driftwood.DogfoodScenario.build(
        org_id: org_id,
        tier: "growth",
        mrr_cents: 250_000,
        lane: "TX->CA"
      )

      # A SECOND brokerage org so the token-blind cross-tenant aggregate plane has
      # >1 tenant per cohort (k-anon floor). Freight-only; no inherited rows needed.
      Driftwood.DogfoodScenario.build(
        org_id: "b1112d00-0000-4000-8000-000000000002",
        tier: "growth",
        mrr_cents: 300_000,
        lane: "TX->CA"
      )
    end

    demo_all(org_id)

    {:ok, _agg} = Driftwood.Aggregate.Rebuild.run(Driftwood.Repo)

    org_id
  end

  # -- guards ----------------------------------------------------------------

  defp seeded?(org_id) do
    actor = %{org_id: org_id, role: :admin, plane: :tenant, kind: :tenant}

    Driftwood.Support.Agent
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
    |> Ash.Query.filter(org_id == ^org_id and handle == "claims-desk")
    |> Ash.exists?(actor: actor, authorize?: false)
  end

  defp fleet_seeded?(org_id) do
    actor = %{org_id: org_id, role: :member, plane: :tenant, kind: :tenant}

    Driftwood.Crm.Company
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.exists?(actor: actor, authorize?: false)
  end

  # -- CRM builders ----------------------------------------------------------

  # The Tier-1 custom fields the inherited-scope rows write (T3.8: a custom-bag value
  # is rejected unless a `tnt_field` definition exists). `company_role` rides the
  # Company bag; `lane` rides the Opportunity bag. All non-PII. Idempotent
  # (define_field is on_conflict: :replace).
  defp define_custom_fields(org_id) do
    for {table, field} <- [
          {"fcm_company", "company_role"},
          {"fcm_company", "plan_tier"},
          {"fcm_company", "mrr_cents"},
          {"fop_opportunity", "lane"}
        ] do
      {:ok, _} =
        Samen.CustomFields.define_field(
          %{org_id: org_id, table_name: table, field_name: field, type: :string},
          Driftwood.Repo
        )
    end

    :ok
  end

  defp seed_companies(org_id) do
    for %{name: name, role: role} <- @companies, into: %{} do
      company =
        Driftwood.Crm.Company
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, name: name, custom: %{"company_role" => role}},
          authorize?: false
        )
        |> Ash.create!()

      {name, company}
    end
  end

  defp seed_people(org_id, companies) do
    for {company_name, first, last, title, email, phone} <- @people do
      company = Map.fetch!(companies, company_name)

      Driftwood.Crm.Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          company_id: company.id,
          display_name: "#{first} #{last}",
          job_title: title,
          full_name: %Samen.Type.FullName{first: first, last: last},
          emails: [%{label: "work", address: email}],
          phones: [%{label: "mobile", number: phone}]
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  defp seed_opportunities(org_id, companies) do
    stage_ids = pipeline_stage_ids(org_id)
    # Round-robin opportunities across shipper companies.
    shippers =
      @companies
      |> Enum.filter(&(&1.role == "shipper"))
      |> Enum.map(&Map.fetch!(companies, &1.name))

    @opportunities
    |> Enum.with_index()
    |> Enum.each(fn {{name, value, status, stage}, idx} ->
      company = Enum.at(shippers, rem(idx, length(shippers)))

      Driftwood.Crm.Opportunity
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: name,
          value_cents: value,
          status: status,
          company_id: company.id,
          pipeline_id: Map.get(stage_ids, stage),
          custom: %{"lane" => "US"}
        },
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()
    end)
  end

  defp pipeline_stage_ids(org_id) do
    actor = %{org_id: org_id, role: :admin}

    Driftwood.Crm.Pipeline
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(actor: actor, authorize?: false)
    |> Map.new(fn stage -> {stage.name, stage.id} end)
  end

  # -- Billing builders ------------------------------------------------------

  defp seed_billing(org_id) do
    plans =
      for %{name: name, label: label, price_cents: cents} <- @plans, into: %{} do
        plan =
          Driftwood.Billing.Plan
          |> Ash.Changeset.for_create(
            :create,
            %{org_id: org_id, name: name, label: label, interval: :monthly, enabled: true},
            actor: %{org_id: org_id, role: :admin},
            authorize?: false
          )
          |> Ash.create!()

        Driftwood.Billing.Price
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            plan_id: plan.id,
            unit_amount_cents: cents,
            currency: "USD",
            interval: :monthly,
            active: true
          },
          actor: %{org_id: org_id, role: :admin},
          authorize?: false
        )
        |> Ash.create!()

        {name, plan}
      end

    customers =
      for {_company_name, billing_name, billing_email, status} <- @customers do
        Driftwood.Billing.Customer
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            billing_name: billing_name,
            billing_email: billing_email,
            status: status,
            currency: "USD"
          },
          authorize?: false
        )
        |> Ash.create!()
      end

    {plans, customers}
  end

  defp seed_subscriptions_and_invoices(org_id, plans, customers) do
    plan_cycle = ["starter", "growth", "scale"]
    actor = %{org_id: org_id, role: :admin}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    customers
    |> Enum.with_index()
    |> Enum.each(fn {customer, idx} ->
      plan = Map.fetch!(plans, Enum.at(plan_cycle, rem(idx, 3)))

      sub =
        Driftwood.Billing.Subscription
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            customer_id: customer.id,
            plan_id: plan.id,
            status: :active,
            current_period_start: DateTime.add(now, -20 * 86_400, :second),
            current_period_end: DateTime.add(now, 10 * 86_400, :second)
          },
          actor: actor,
          authorize?: false
        )
        |> Ash.create!()

      # ~10 invoices total across customers: a paid + an open/overdue per customer,
      # plus an extra overdue on the first two for the mix.
      seed_invoice(org_id, actor, customer, sub, now, :paid, idx)
      seed_invoice(org_id, actor, customer, sub, now, invoice_status(idx), idx + 100)
    end)
  end

  defp invoice_status(idx) when rem(idx, 3) == 0, do: :open
  defp invoice_status(idx) when rem(idx, 3) == 1, do: :open
  defp invoice_status(_idx), do: :void

  defp seed_invoice(org_id, actor, customer, sub, now, status, seq) do
    amount = 25_000 + rem(seq, 5) * 10_000

    {amount_paid, paid_at, due_date} =
      case status do
        :paid ->
          {amount, DateTime.add(now, -5 * 86_400, :second), DateTime.add(now, -5 * 86_400, :second)}

        :open ->
          # Half of the open invoices are OVERDUE (due date in the past).
          due = if rem(seq, 2) == 0, do: DateTime.add(now, -3 * 86_400, :second), else: DateTime.add(now, 12 * 86_400, :second)
          {0, nil, due}

        _ ->
          {0, nil, DateTime.add(now, 10 * 86_400, :second)}
      end

    invoice =
      Driftwood.Billing.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer.id,
          subscription_id: sub.id,
          status: status,
          amount_due_cents: amount,
          amount_paid_cents: amount_paid,
          currency: "USD",
          period_start: DateTime.add(now, -30 * 86_400, :second),
          period_end: now,
          due_date: due_date,
          paid_at: paid_at,
          line_items: [%{"description" => "Brokerage platform — monthly", "amount_cents" => amount, "quantity" => 1}]
        },
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()

    # A couple of payments (on the paid invoices).
    if status == :paid do
      Driftwood.Billing.Payment
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          invoice_id: invoice.id,
          customer_id: customer.id,
          status: :succeeded,
          amount_cents: amount,
          currency: "USD",
          payment_method_type: :ach,
          last4: "4242",
          paid_at: paid_at
        },
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()
    end

    invoice
  end

  # -- Support builders ------------------------------------------------------

  defp seed_support(org_id) do
    actor = %{org_id: org_id, role: :admin}
    member = %{org_id: org_id, role: :member}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # An SLA policy (Tier-0 config).
    sla =
      Driftwood.Support.Sla
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "standard",
          label: "Standard freight dispute SLA",
          first_response_minutes: 60,
          resolve_minutes: 480,
          priority: :normal,
          enabled: true
        },
        actor: actor,
        authorize?: false
      )
      |> Ash.create!()

    # A canned-response macro (Tier-0 config).
    Driftwood.Support.Macro
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        name: "detention-ack",
        description: "Acknowledge a detention-charge dispute",
        body_template: "Thanks for flagging the detention charge on {{load}}. We are pulling the check-call log and will respond within one business day.",
        category: "disputes",
        tags: ["detention", "dispute"],
        enabled: true
      },
      actor: actor,
      authorize?: false
    )
    |> Ash.create!()

    # 2-3 agents WITH PII.
    agents =
      for {handle, first, last, email, role} <- @agents do
        Driftwood.Support.Agent
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            handle: handle,
            full_name: %Samen.Type.FullName{first: first, last: last},
            email: email,
            role: role,
            status: :active,
            timezone: "America/New_York"
          },
          authorize?: false
        )
        |> Ash.create!()
      end

    [primary_agent | _] = agents

    @tickets
    |> Enum.with_index()
    |> Enum.each(fn {{subject, status, priority}, idx} ->
      agent = Enum.at(agents, rem(idx, length(agents)))

      resolved_at =
        if status in [:resolved, :closed], do: DateTime.add(now, -1 * 86_400, :second), else: nil

      ticket =
        Driftwood.Support.Ticket
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            subject: subject,
            status: status,
            priority: priority,
            sla_id: sla.id,
            sla_breach_at: DateTime.add(now, sla.resolve_minutes * 60, :second),
            resolved_at: resolved_at,
            tags: ["freight-dispute"]
          },
          actor: member,
          authorize?: false
        )
        |> Ash.create!()

      # A conversation + a couple of messages on the first few tickets.
      if idx < 4 do
        conversation =
          Driftwood.Support.Conversation
          |> Ash.Changeset.for_create(
            :create,
            %{org_id: org_id, ticket_id: ticket.id, channel: :email, status: :open, subject: subject},
            actor: member,
            authorize?: false
          )
          |> Ash.create!()

        # Inbound customer message (body is vault-routed PII).
        Driftwood.Support.Message
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            conversation_id: conversation.id,
            sender_type: :customer,
            message_type: :reply,
            created_via: :email,
            body: "Hi — we are disputing the charge referenced in \"#{subject}\". Please review the rate confirmation and check-call log."
          },
          authorize?: false
        )
        |> Ash.create!()

        # Agent reply (body is vault-routed PII; sender is an agent).
        Driftwood.Support.Message
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            conversation_id: conversation.id,
            agent_id: agent.id,
            sender_type: :agent,
            sender_id: agent.id,
            message_type: :reply,
            created_via: :web,
            body: "Thanks — we have opened a case and pulled the documents. We will follow up within one business day."
          },
          authorize?: false
        )
        |> Ash.create!()
      end

      # A CSAT on the two resolved tickets.
      if status == :resolved do
        Driftwood.Support.Csat
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            ticket_id: ticket.id,
            agent_id: primary_agent.id,
            score: 4 + rem(idx, 2),
            comments: "Resolved quickly, appreciated the follow-up.",
            channel: :email,
            responded_at: now
          },
          actor: member,
          authorize?: false
        )
        |> Ash.create!()
      end
    end)

    :ok
  end
end
