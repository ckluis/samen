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

  # WS-A A5 (demo coherence) — the JUST-ONBOARDED tenant org: an operator ACCOUNT exists
  # (Lakeline Freight Co — seeded by `Driftwood.OperatorSeeds`), but the tenant plane is
  # deliberately EMPTY, so opening it demonstrates the framework first-run checklist +
  # kit empty states + the guarded sample-data offer. `dev_seed/0` seeds NOTHING for it.
  @empty_org_id "b1112d00-0000-4000-8000-000000000006"

  @doc "The deliberately-EMPTY (just-onboarded) tenant org id — first-run/empty-state demo."
  def empty_org_id, do: @empty_org_id

  # ADR-013 §8.1 — the FIVE named brokerages (fixed uuids so dev links + tests are stable),
  # each fully populated across every module + plane. Varied name/lane/tier/MRR so the accounts
  # table, Portfolio aggregate, and dunning surface look alive (mixed health, ≥2 per cohort).
  #
  # Each spec also carries the per-tenant BRANDING (task: "make it VARIED and realistic — different
  # sizes/health/lanes so the operator dashboard tells a story"): `domain`, the brokerage's own
  # `carriers`/`shippers`/`factoring` partner Company names, a `prefix` for its load/ticket numbers,
  # its `origin`/`dest` cities + `equipment`, and a `size` band (small/mid/large — drives contact
  # count & fleet size). All branded strings the CRM/Billing/Support/Marketing/Chat seeders derive
  # from THIS spec, so an operator drilling into Summit sees Summit's carriers/contacts/emails —
  # not a Blue-Ridge clone.
  @brokerages [
    %{
      org_id: "b1112d00-0000-4000-8000-000000000001",
      name: "Blue Ridge Logistics", lane: "TX->CA", tier: "growth", mrr_cents: 250_000,
      domain: "blueridgelogistics.example", prefix: "BR", size: :mid,
      origin: "Dallas", dest: "Los Angeles", equipment: "dry van",
      carriers: ["Appalachian Freight Lines", "Smoky Mountain Trucking", "Piedmont Haulers"],
      shippers: ["Asheville Brewing Supply", "Carolina Textile Mills", "Blue Ridge Bottling", "Tarheel Building Products"],
      factoring: "Ridgeline Factoring Partners"
    },
    %{
      org_id: "b1112d00-0000-4000-8000-000000000002",
      name: "Summit Freight Partners", lane: "IL->GA", tier: "growth", mrr_cents: 300_000,
      domain: "summitfreight.example", prefix: "SF", size: :mid,
      origin: "Chicago", dest: "Atlanta", equipment: "reefer",
      carriers: ["Great Lakes Line Haul", "Prairie State Carriers", "Windy City Transport"],
      shippers: ["Midwest Cold Storage", "Peachtree Foods", "Lakeshore Packaging", "Dixie Beverage Co"],
      factoring: "Summit Capital Factoring"
    },
    %{
      org_id: "b1112d00-0000-4000-8000-000000000003",
      name: "Gulf Stream Carriers", lane: "FL->NY", tier: "scale", mrr_cents: 480_000,
      domain: "gulfstreamcarriers.example", prefix: "GS", size: :large,
      origin: "Miami", dest: "Newark", equipment: "flatbed",
      carriers: ["Everglades Transport", "Palmetto Line Haul", "Atlantic Coast Trucking", "Biscayne Freight Systems"],
      shippers: ["Sunshine Produce Exchange", "Empire Steel Supply", "Coastal Marine Outfitters", "Hudson Valley Distributors"],
      factoring: "Gulf Coast Factoring Group"
    },
    %{
      org_id: "b1112d00-0000-4000-8000-000000000004",
      name: "Cascade Freightways", lane: "WA->AZ", tier: "starter", mrr_cents: 120_000,
      domain: "cascadefreightways.example", prefix: "CF", size: :small,
      origin: "Seattle", dest: "Phoenix", equipment: "dry van",
      carriers: ["Rainier Regional Carriers", "Columbia River Transport"],
      shippers: ["Emerald City Roasters", "Desert Valley Produce", "Pacific Timber Products"],
      factoring: "Evergreen Factoring"
    },
    %{
      org_id: "b1112d00-0000-4000-8000-000000000005",
      name: "Ironline Brokerage", lane: "OH->TX", tier: "scale", mrr_cents: 520_000,
      domain: "ironlinebrokerage.example", prefix: "IL", size: :large,
      origin: "Columbus", dest: "Houston", equipment: "flatbed",
      carriers: ["Rust Belt Line Haul", "Buckeye Freight Systems", "Ohio Valley Trucking", "Great Plains Carriers"],
      shippers: ["Midland Steel Works", "Lone Star Chemicals", "Rubber City Manufacturing", "Gulf Petro Supply"],
      factoring: "Ironclad Capital Partners"
    }
  ]

  # Fallback spec for an org NOT in @brokerages (the *_ui_test / demo_seeds_test seed an arbitrary
  # generated org id and still need branded-but-generic content). Keyed off Blue Ridge branding.
  @default_spec List.first(@brokerages)

  @doc "The FIVE seeded brokerage specs (ADR-013 §8.1). Consumed by the operator seed too."
  def brokerages, do: @brokerages

  @doc """
  The brokerage spec for `org_id` — the matching `@brokerages` entry, or the Blue Ridge default
  (so `demo_all/1` called on an arbitrary test org still produces branded, non-empty data).
  """
  def spec_for(org_id) do
    Enum.find(@brokerages, @default_spec, &(&1.org_id == org_id))
  end

  # First names + surnames the per-tenant contact/agent generators draw from (deterministic by
  # index so a re-seed is stable and NO two tenants share a contact roster — each tenant slices a
  # different window of the pool via its org-derived offset).
  @first_names ~w(Dana Marcus Priya Cole Yuki Rosa Ellis Nadia Tomas Grace Owen Amara Sofia Isaac
                  Leah Desmond Yolanda Peter Bianca Warren Terrence Mei Andre Sasha Hiro Camille
                  Dmitri Fatima Lucas Ingrid Rafael Nkechi Sven Priscilla Omar Renata)
  @last_names ~w(Whitfield Odell Nair Barrett Tanaka Delgado Grant Osei Vela Lindqvist Fitzgerald
                 Boone Marchetti Kowalski Nakamura Vlahos Reyes Lindholm Mercer Achebe Iyer Zhang
                 Okonkwo Petrov Yamamoto Beaumont Sorensen Adeyemi Castellano Novak Bergstrom
                 Haddad Montoya Okafor Farrell Delacroix)

  # Per-tenant contact TITLES (round-robined so the CRM roster shows dispatchers, reps, AP, ops).
  @contact_titles ["dispatcher", "carrier rep", "shipper contact", "AP clerk", "operations manager", "logistics coordinator"]

  # Billing plans (Tier-0 config): the brokerage's SaaS tiers.
  @plans [
    %{name: "starter", label: "Starter", price_cents: 9_900},
    %{name: "growth", label: "Growth", price_cents: 29_900},
    %{name: "scale", label: "Scale", price_cents: 79_900}
  ]

  # Support agents (the tenant's OWN helpdesk staff): fixed handles + names, but the EMAIL is
  # derived per-tenant from the spec domain (sofia.marchetti@summitfreight.example on Summit,
  # …@blueridgelogistics on Blue Ridge). Internal staff, so names are stable across tenants —
  # the tenant-facing VARIETY lives in the carriers/shippers/contacts/loads. {handle, first,
  # last, role}.
  @agent_slots [
    {"claims-desk", "Sofia", "Marchetti", :supervisor},
    {"dispatch-support", "Isaac", "Kowalski", :agent},
    {"billing-support", "Leah", "Nakamura", :agent}
  ]

  # ~8 CRM companies per tenant — DERIVED from the spec's own carriers + shippers + factoring
  # partner (task: each tenant shows its OWN book, not a Blue-Ridge clone). FIXED shape (3
  # carriers + 4 shippers + 1 factoring = 8) so the per-org count is uniform across tenants
  # (the *_ui_test / demo_seeds_test assert 8); the variety is in the NAMES, not the count. A
  # spec with fewer carriers/shippers cycles its list to fill the slots.
  defp companies_for(spec) do
    carriers = spec.carriers |> Stream.cycle() |> Enum.take(3) |> Enum.map(&%{name: &1, role: "carrier"})
    shippers = spec.shippers |> Stream.cycle() |> Enum.take(4) |> Enum.map(&%{name: &1, role: "shipper"})
    factoring = [%{name: spec.factoring, role: "factoring"}]
    carriers ++ shippers ++ factoring
  end

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

    spec = spec_for(org_id)

    if seeded?(org_id) do
      org_id
    else
      :ok = define_custom_fields(org_id)

      companies = seed_companies(org_id, spec)
      people = seed_people(org_id, spec, companies)
      seed_activities(org_id, people)
      seed_opportunities(org_id, spec, companies)

      {plans, customers} = seed_billing(org_id, spec)
      seed_subscriptions_and_invoices(org_id, plans, customers)

      seed_support(org_id, spec)

      org_id
    end
    |> tap(fn seeded_org ->
      # Marketing (ADR-011 §7) is seeded with its OWN marker so it lands even when the
      # inherited-scope guard above short-circuits an already-seeded org (a re-run after the
      # Marketing mount shipped). Idempotent.
      seed_marketing(seeded_org, spec)

      # Chat (ADR-012, the flagship) is seeded with its OWN marker too — 3 threads per tenant,
      # including one cross-plane thread (a tenant admin ↔ a SaaS agent) whose message pastes a
      # `samen:crm.person:<id>` ref so object unfurl is provable in the LIVE app (tenant clear /
      # operator ••••). Idempotent.
      seed_chat(seeded_org, spec)

      # Notifications (WS-A A4/A5, demo coherence) — 3 curated ones per tenant through
      # the REAL kernel engine (`Samen.Notifications.Engine.notify/1`: vault-routed body,
      # audit, id-only broadcast), on TOP of the invoice.* notifications the wired kernel
      # event sources already fired organically during the billing seed. One is marked
      # read so the inbox shows a read/unread mix. Idempotent (own marker).
      seed_notifications(seeded_org, spec)
    end)
  end

  @doc """
  Full DEV seed (ADR-013 §8) — the FIVE named brokerages, each FULLY populated across every
  module + plane. Per brokerage: the freight fleet (carriers/shippers/drivers/loads/dispatch/
  settlement + broker rollup) via `DogfoodScenario.build/1`, then the inherited universal scopes
  (CRM · Billing · Support · Marketing · Chat) via `demo_all/1`. Then the cross-tenant aggregate
  is rebuilt (spanning all 5 orgs) and the OPERATOR org's book of business OVER all five is stood
  up (`OperatorSeeds.seed/0` — accounts · platform billing · desk · leads). Returns the primary
  (Blue Ridge Logistics) org id.

  Safe to re-run: the freight fleet + inherited rows are each guarded per-org by a marker, so a
  re-run of `mix driftwood.seed` is idempotent.
  """
  def dev_seed do
    for %{org_id: org_id} = spec <- @brokerages do
      unless fleet_seeded?(org_id) do
        Driftwood.DogfoodScenario.build(
          org_id: org_id,
          tier: spec.tier,
          mrr_cents: spec.mrr_cents,
          lane: spec.lane,
          # The DogfoodScenario fleet carrier/shipper are DEDICATED names (an in-house asset fleet
          # + a lead shipper) so they never duplicate demo_all's carriers/shippers.
          carrier: "#{spec.name} Fleet Services",
          shipper: "#{spec.origin} Regional Distribution",
          origin: spec.origin,
          dest: spec.dest,
          equipment: spec.equipment,
          prefix: spec.prefix
        )
      end

      demo_all(org_id)
    end

    {:ok, _agg} = Driftwood.Aggregate.Rebuild.run(Driftwood.Repo)

    # ADR-010/013 — the OPERATOR org's book of business OVER the seeded tenant orgs: the SaaS
    # company (Samen SaaS, Inc.) whose ACCOUNTS ARE these five freight brokerages, each with a
    # tenant-admin (PII the SaaS owns — CLEAR to the operator), a platform subscription (2 orgs
    # past-due for dunning), tenant-filed desk tickets, and the operator's own not-yet-customer
    # Leads. Renders at `/operator/accounts` · `/billing` · `/desk` · `/marketing/leads`.
    :ok = Driftwood.OperatorSeeds.seed()

    @blue_ridge_org_id
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
    # ADR-011 §8/§9: lifecycle_stage + social handles are Tier-1 custom-field conventions on
    # the Person bag (`fpr_person`). Social handles are FLAT string keys (`social_<network>`)
    # because the kernel custom bag has no `:map` type — each is a URL/handle string, non-PII
    # (a public profile URL). lifecycle_stage is a bounded string set enforced at the UI layer.
    for {table, field} <- [
          {"fcm_company", "company_role"},
          {"fcm_company", "plan_tier"},
          {"fcm_company", "mrr_cents"},
          {"fop_opportunity", "lane"},
          {"fpr_person", "lifecycle_stage"},
          {"fpr_person", "social_linkedin"},
          {"fpr_person", "social_twitter"}
        ] do
      {:ok, _} =
        Samen.CustomFields.define_field(
          %{org_id: org_id, table_name: table, field_name: field, type: :string},
          Driftwood.Repo
        )
    end

    :ok
  end

  defp seed_companies(org_id, spec) do
    for %{name: name, role: role} <- companies_for(spec), into: %{} do
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

  # Lifecycle stages round-robined across the seeded people (ADR-011 §8 bounded set).
  @lifecycle_cycle ~w(lead mql sql customer lead sql customer mql lead sql customer mql)

  # A per-org OFFSET into the name pools so NO two tenants share a contact roster (the operator
  # drilling from Blue Ridge into Summit sees different people). Keyed off the brokerage's POSITION
  # in @brokerages (× a stride) so each of the five gets a distinct, DETERMINISTIC window — and an
  # org NOT in @brokerages (the *_ui_test / demo_seeds_test generated org) maps to position 0
  # (Blue Ridge branding, offset 0 → "Dana Whitfield" first), keeping those tests stable.
  defp name_offset(org_id) do
    idx = Enum.find_index(@brokerages, &(&1.org_id == org_id)) || 0
    idx * 7
  end

  # 12 people per tenant — carrier dispatchers/reps + shipper contacts/AP clerks, each attached to
  # one of the tenant's own Companies, with a tenant-domain work email so PII masking is
  # demonstrable AND the roster reads as THIS brokerage's book. Names sliced from the pool at the
  # org offset so tenants don't collide. Deterministic (index-driven), so a re-seed is stable.
  defp seed_people(org_id, spec, companies) do
    company_list = Map.values(companies)
    offset = name_offset(org_id)

    for idx <- 0..11 do
      first = Enum.at(@first_names, rem(offset + idx, length(@first_names)))
      last = Enum.at(@last_names, rem(offset * 3 + idx * 5, length(@last_names)))
      title = Enum.at(@contact_titles, rem(idx, length(@contact_titles)))
      company = Enum.at(company_list, rem(idx, length(company_list)))
      handle = "#{String.downcase(first)}.#{String.downcase(last)}"
      email = "#{handle}@#{spec.domain}"
      phone = "+1-#{200 + rem(offset, 700)}-555-#{String.pad_leading(Integer.to_string(100 + idx * 7), 4, "0")}"

      # PII (full_name/emails/phones) goes through Samen.Factory (WS-D D1.2) — the
      # vault-aware create helper. Same real :create action + Samen.Vault.Change
      # chokepoint as before; the factory is the extracted SampleData/Seeds idiom.
      Samen.Factory.create!(
        Driftwood.Crm.Person,
        Map.merge(
          %{
            org_id: org_id,
            company_id: company.id,
            display_name: "#{first} #{last}",
            job_title: title,
            # ADR-011 §8/§9 Tier-1 conventions: lifecycle stage + social handles (flat
            # string keys; non-PII business-directory URLs — no whitespace, so they pass
            # the custom-bag containment guard).
            custom: %{
              "lifecycle_stage" => Enum.at(@lifecycle_cycle, idx, "lead"),
              "social_linkedin" => "https://linkedin.com/in/#{handle}",
              "social_twitter" => "https://x.com/#{handle}"
            }
          },
          Samen.Factory.person(first, last, email: email, phone: phone)
        ),
        authorize?: false
      )
    end
  end

  # ADR-011 §6/§10.2: seed a handful of freight-flavored CheckCall activities per contact
  # (Driftwood re-identifies Activity as CheckCall) so the timeline renders real data.
  # A mix of note/call/email/meeting/task, all completed. Non-PII rows.
  @activity_templates [
    {:call, "Check call — ETA confirmed", "Driver on schedule; delivering within the appointment window."},
    {:email, "Rate confirmation sent", "Sent the rate con for the next lane; awaiting signed copy."},
    {:note, "Left voicemail", "No answer at the dock; left a callback number."},
    {:meeting, "Quarterly business review", "Reviewed lane volume and on-time percentage for the quarter."},
    {:task, "Follow up on detention", "Chase the detention paperwork before month-end billing."}
  ]

  defp seed_activities(org_id, people) do
    people
    |> Enum.with_index()
    |> Enum.each(fn {person, p_idx} ->
      # 3 activities per person, rotating through the templates for variety.
      for offset <- 0..2 do
        {type, subject, body} = Enum.at(@activity_templates, rem(p_idx + offset, length(@activity_templates)))

        Driftwood.Crm.Activity
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            person_id: person.id,
            company_id: person.company_id,
            type: type,
            subject: subject,
            body: body,
            status: :completed,
            completed_at: DateTime.add(DateTime.utc_now(), -offset * 86_400, :second) |> DateTime.truncate(:second)
          },
          actor: %{org_id: org_id, role: :member},
          authorize?: false
        )
        |> Ash.create!()
      end
    end)
  end

  # 6 loads (Opportunity) per tenant — DERIVED from the spec's lane/equipment/prefix, spanning the
  # freight lifecycle stages AND the Opportunity status enum (open/won/lost/on_hold) so the load
  # board + pipeline show status variety (task: "loads across statuses"). {load#, value, status,
  # stage}.
  @load_templates [
    {1, 480_000, :open, "quoted"},
    {2, 620_000, :open, "booked"},
    {3, 410_000, :open, "dispatched"},
    {4, 535_000, :on_hold, "in_transit"},
    {5, 590_000, :won, "delivered"},
    {6, 445_000, :lost, "quoted"}
  ]

  defp seed_opportunities(org_id, spec, companies) do
    stage_ids = pipeline_stage_ids(org_id)
    # Round-robin loads across the tenant's OWN shipper companies.
    shippers =
      companies
      |> Map.values()
      |> Enum.filter(fn c -> Map.get(c.custom || %{}, "company_role") == "shipper" end)

    shippers = if shippers == [], do: Map.values(companies), else: shippers
    base = 4400 + rem(name_offset(org_id), 500)

    @load_templates
    |> Enum.with_index()
    |> Enum.each(fn {{n, value, status, stage}, idx} ->
      company = Enum.at(shippers, rem(idx, length(shippers)))
      load_no = "#{spec.prefix}-#{base + n}"
      name = "#{load_no} #{spec.origin} -> #{spec.dest} #{spec.equipment}"

      Driftwood.Crm.Opportunity
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: name,
          # ADR-036 §4.5(5): value_cents/currency dropped by the H1 Money
          # migration — construct the Money value directly.
          value: Samen.Type.Money.from_cents(value, :USD),
          status: status,
          company_id: company.id,
          pipeline_id: Map.get(stage_ids, stage),
          custom: %{"lane" => spec.lane}
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

  # 6 billing customers per tenant — the brokerage's OWN shipper billing accounts + a carrier
  # settlement account, DERIVED from the spec so the tenant's Billing page reads as its own book
  # (billing_name/billing_email are scalar-vaulted PII).
  defp customers_for(spec) do
    shippers = spec.shippers |> Stream.cycle() |> Enum.take(4)
    carriers = spec.carriers |> Stream.cycle() |> Enum.take(2)

    shipper_rows =
      Enum.map(shippers, fn name ->
        slug = billing_slug(name)
        {name, "#{name} Inc", "ap@#{slug}.example", :active}
      end)

    carrier_rows =
      carriers
      |> Enum.with_index()
      |> Enum.map(fn {name, idx} ->
        slug = billing_slug(name)
        status = if idx == 1, do: :inactive, else: :active
        {name, "#{name} (carrier settlement)", "settlements@#{slug}.example", status}
      end)

    shipper_rows ++ carrier_rows
  end

  defp billing_slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
    |> String.slice(0, 20)
  end

  defp seed_billing(org_id, spec) do
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
            # ADR-036 §4.5(5): unit_amount_cents/currency dropped by the H1 Money
            # migration — construct the Money value directly.
            unit_amount: Samen.Type.Money.from_cents(cents, :USD),
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
      for {_company_name, billing_name, billing_email, status} <- customers_for(spec) do
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

  # 3 support agents per tenant — the tenant's OWN helpdesk staff (fixed names, tenant-domain
  # emails; both full_name + email are vaulted). {handle, first, last, email, role}.
  defp agents_for(_org_id, spec) do
    Enum.map(@agent_slots, fn {handle, first, last, role} ->
      email = "#{String.downcase(first)}.#{String.downcase(last)}@#{spec.domain}"
      {handle, first, last, email, role}
    end)
  end

  # 10 support tickets per tenant — freight disputes across statuses/priorities, referencing THIS
  # tenant's own load numbers + carriers. {subject, status, priority}.
  defp tickets_for(org_id, spec) do
    base = 4400 + rem(name_offset(org_id), 500)
    load = fn n -> "#{spec.prefix}-#{base + n}" end
    [c1, c2 | _] = spec.carriers |> Stream.cycle() |> Enum.take(2)

    [
      {"Detention charge on load #{load.(1)}", :open, :high},
      {"Missing BOL for #{load.(3)} delivery", :open, :urgent},
      {"Carrier no-show — #{c1} #{load.(2)}", :pending, :urgent},
      {"Reweigh dispute on #{load.(4)} #{spec.equipment}", :pending, :normal},
      {"Lumper fee reimbursement #{load.(5)}", :open, :normal},
      {"POD not received for #{load.(6)}", :pending, :high},
      {"Overcharge on fuel surcharge #{load.(1)}", :open, :normal},
      {"Damaged freight claim #{load.(4)}", :on_hold, :high},
      {"Late delivery penalty inquiry — #{c2} #{load.(2)}", :resolved, :low},
      {"Rate confirmation mismatch #{load.(5)}", :resolved, :normal}
    ]
  end

  defp seed_support(org_id, spec) do
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

    # 2-3 agents WITH PII (the tenant's own helpdesk staff — tenant-domain emails).
    # PII (full_name + scalar email) routes through Samen.Factory (WS-D D1.2).
    agents =
      for {handle, first, last, email, role} <- agents_for(org_id, spec) do
        Samen.Factory.create!(
          Driftwood.Support.Agent,
          Map.merge(
            %{
              org_id: org_id,
              handle: handle,
              email: email,
              role: role,
              status: :active,
              timezone: "America/New_York"
            },
            Samen.Factory.person(first, last)
          ),
          authorize?: false
        )
      end

    [primary_agent | _] = agents

    tickets_for(org_id, spec)
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

  # -- Marketing (ADR-011 §7) --------------------------------------------------
  #
  # Seed a carrier-outreach campaign + template + segments + subscribers built from the seeded
  # contacts' emails (vaulted on the subscriber row) + at least ONE suppression row, so the
  # Marketing pages populate AND the "send refuses a suppressed subscriber" red path is
  # provable in the dogfood. Subscriber email is 🔒 vault PII (clear on tenant / •••• on
  # operator). `people` are the seeded CRM Person structs; the plaintext emails come from the
  # `@people` catalog (the org owns its contacts' PII on the tenant plane).
  defp seed_marketing(org_id, spec) do
    if marketing_seeded?(org_id) do
      :ok
    else
      do_seed_marketing(org_id, spec)
    end
  end

  defp marketing_seeded?(org_id) do
    actor = %{org_id: org_id, role: :admin, plane: :tenant, kind: :tenant}

    Driftwood.Marketing.Campaign
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.exists?(actor: actor, authorize?: false)
  rescue
    _ -> false
  end

  defp do_seed_marketing(org_id, spec) do
    admin = %{org_id: org_id, role: :admin, plane: :tenant, kind: :tenant}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _template =
      Driftwood.Marketing.Template
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "Carrier onboarding",
          subject_line: "Partner with #{spec.name} on your next #{spec.lane} lane",
          body_html: "<p>We have consistent #{spec.equipment} freight on the #{spec.origin}→#{spec.dest} lane — let's talk rates.</p>",
          from_name: spec.name,
          from_address: "carriers@#{spec.domain}",
          enabled: true
        },
        actor: admin,
        authorize?: false
      )
      |> Ash.create!()

    # Subscribers from THIS tenant's own carrier contacts (tenant-domain emails). The FIRST is
    # deliverable (active); the LAST gets a suppression row (opted out) so the red path is
    # demonstrable. Derived from the same name pool + domain as the CRM roster.
    offset = name_offset(org_id)

    subscriber_emails =
      for idx <- 0..5 do
        first = Enum.at(@first_names, rem(offset + idx, length(@first_names)))
        last = Enum.at(@last_names, rem(offset * 3 + idx * 5, length(@last_names)))
        "#{String.downcase(first)}.#{String.downcase(last)}@#{spec.domain}"
      end

    subscribers =
      Enum.with_index(subscriber_emails)
      |> Enum.map(fn {email, idx} ->
        Driftwood.Marketing.Subscriber
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org_id,
            email: email,
            status: :active,
            consent_at: now,
            source: "crm"
          },
          authorize?: false
        )
        |> Ash.create!()
        |> then(fn s -> {idx, s} end)
      end)
      |> Map.new()

    active_count = map_size(subscribers)

    # The SUPPRESSION row — the last seeded subscriber opted out. A send to it MUST refuse.
    suppressed = Map.fetch!(subscribers, active_count - 1)

    _suppression =
      Driftwood.Marketing.Suppression
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          subscriber_id: suppressed.id,
          reason: :unsubscribed,
          active: true,
          suppressed_at: now,
          notes: "Opted out via the unsubscribe link"
        },
        actor: admin,
        authorize?: false
      )
      |> Ash.create!()

    _segment =
      Driftwood.Marketing.Segment
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "Active carriers",
          description: "Carriers who have opted in to lane offers",
          filter_criteria: %{"status" => "active"},
          subscriber_count: active_count
        },
        actor: admin,
        authorize?: false
      )
      |> Ash.create!()

    _campaign =
      Driftwood.Marketing.Campaign
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: "Q3 lane-offer outreach",
          description: "Outreach to active carriers about consistent Q3 freight",
          status: :draft
        },
        actor: admin,
        authorize?: false
      )
      |> Ash.create!()

    :ok
  end

  # ==========================================================================
  # Chat (ADR-012, the FLAGSHIP) — 3 threads per tenant (the brokerage → Driftwood support),
  # including one CROSS-PLANE thread whose message pastes a `samen:crm.person:<id>` (+ a
  # `samen:freight.driver:<id>`) ref so object unfurl is provable in the LIVE app (tenant clear /
  # operator ••••). All spec-branded (subject references the tenant's own load number, the tenant
  # participant handle is the tenant's slug). Idempotent (its own marker).
  # ==========================================================================

  defp seed_chat(org_id, spec) do
    if chat_seeded?(org_id) do
      :ok
    else
      do_seed_chat(org_id, spec)
    end
  end

  defp chat_seeded?(org_id) do
    actor = %{org_id: org_id, role: :admin, plane: :tenant, kind: :tenant}

    Driftwood.Chat.ChatThread
    |> Ash.Query.for_read(:read, %{}, actor: actor, authorize?: false)
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.exists?(actor: actor, authorize?: false)
  rescue
    _ -> false
  end

  defp do_seed_chat(org_id, spec) do
    person = first_person(org_id)
    driver = first_driver(org_id)
    base = 4400 + rem(name_offset(org_id), 500)
    load_no = "#{spec.prefix}-#{base + 1}"
    tenant_handle = tenant_slug(spec) <> "-dispatch"

    # THREAD 1 — the flagship CROSS-PLANE thread with the object-unfurl message (referencing THIS
    # tenant's own contact + driver). Kept first so it is the marker + the unfurl demo.
    refs =
      [person && "samen:crm.person:#{person.id}", driver && "samen:freight.driver:#{driver.id}"]
      |> Enum.reject(&is_nil/1)

    body =
      "Confirming the rate for #{load_no}. Point of contact: " <>
        (person && "samen:crm.person:#{person.id}" || "TBD") <>
        (if(driver, do: " · assigned driver samen:freight.driver:#{driver.id}", else: ""))

    seed_thread(org_id, spec, tenant_handle,
      subject: "Rate confirmation for load #{load_no}",
      kind: :cross_plane,
      disclosure_mode: :masked,
      body: body,
      refs: refs
    )

    # THREAD 2 — a billing question the brokerage filed with Driftwood support (cross-plane, no
    # unfurl). Gives /chat a real inbox with more than one row per tenant.
    seed_thread(org_id, spec, tenant_handle,
      subject: "Question about our #{String.capitalize(spec.tier)} plan invoice",
      kind: :cross_plane,
      disclosure_mode: :masked,
      body: "Our latest platform invoice looks higher than last month — can you break down the #{String.capitalize(spec.tier)}-tier line items?",
      refs: []
    )

    # THREAD 3 — a tenant-internal onboarding thread, so the inbox shows a mix of thread kinds.
    # No operator participant.
    seed_thread(org_id, spec, tenant_handle,
      subject: "Onboarding a new carrier on the #{spec.origin}→#{spec.dest} lane",
      kind: :tenant_internal,
      disclosure_mode: :tenant_wide,
      body: "Adding #{List.first(spec.carriers)} to our #{spec.equipment} pool for the #{spec.lane} lane — what docs do you need?",
      refs: [],
      operator?: false
    )

    :ok
  end

  # Seed ONE chat thread: a tenant participant (+ optionally an operator participant) and one
  # opening message. `opts`: `:subject`, `:kind`, `:disclosure_mode`, `:body`, `:refs`,
  # `:operator?` (default true).
  defp seed_thread(org_id, spec, tenant_handle, opts) do
    operator? = Keyword.get(opts, :operator?, true)

    thread =
      Driftwood.Chat.ChatThread
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          subject: Keyword.fetch!(opts, :subject),
          kind: Keyword.fetch!(opts, :kind),
          status: :open,
          disclosure_mode: Keyword.fetch!(opts, :disclosure_mode)
        },
        authorize?: false
      )
      |> Ash.create!()

    # WS-D D11.1: full_name is the vault-routed composite `Samen.Factory.person/3`
    # builds; adopt the factory so the seeded participant PII takes the SampleData
    # vault path and the physical-column red-path guard applies.
    tenant_participant =
      Samen.Factory.create!(
        Driftwood.Chat.ChatParticipant,
        Map.merge(
          %{
            org_id: org_id,
            thread_id: thread.id,
            party: :tenant,
            principal_kind: :user,
            handle: tenant_handle,
            role: :owner
          },
          Samen.Factory.person("Dispatch", spec.name)
        ),
        authorize?: false
      )

    if operator? do
      Driftwood.Chat.ChatParticipant
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          thread_id: thread.id,
          party: :operator,
          principal_kind: :operator_staff,
          handle: "driftwood-support",
          role: :member
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    Driftwood.Chat.ChatMessage
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        thread_id: thread.id,
        participant_id: tenant_participant.id,
        sender_party: :tenant,
        kind: :message,
        body: Keyword.fetch!(opts, :body),
        refs: Keyword.get(opts, :refs, [])
      },
      authorize?: false
    )
    |> Ash.create!()

    thread
  end

  # -- Notifications (WS-A A4/A5 — demo coherence) -----------------------------
  #
  # NOTE: the billing seeder above ALREADY produces notifications organically — the
  # kernel's wired event sources (`Samen.Notifications.StatusChange`, config'd to
  # `Driftwood.Primitives.Notification` in config.exs) fire on every seeded invoice
  # state change. This seeder ADDS the three curated ones a live tenant would also
  # see, through the SAME kernel engine (vault-routed body + audit + id-only
  # broadcast): an SLA breach, a past-due invoice, and a chat mention whose
  # `subject_ref` unfurls the tenant's own first contact (`samen:crm.person:<id>` →
  # per-plane-masked object_card). The past-due one is marked READ so the inbox shows
  # a read/unread mix. Idempotent (marker = the chat.mention event only THIS seeder
  # writes — the organic invoice.* rows must not short-circuit it).
  defp seed_notifications(org_id, spec) do
    if notifications_seeded?(org_id) do
      :ok
    else
      do_seed_notifications(org_id, spec)
    end
  end

  defp notifications_seeded?(org_id) do
    Driftwood.Primitives.Notification
    |> Ash.Query.filter(org_id == ^org_id and event_type == "chat.mention")
    |> Ash.exists?(authorize?: false)
  rescue
    _ -> false
  end

  defp do_seed_notifications(org_id, spec) do
    person = first_person(org_id)
    recipient_id = Ash.UUID.generate()
    base = 4400 + rem(name_offset(org_id), 500)

    engine_opts = [
      notification_module: Driftwood.Primitives.Notification,
      preference_module: Driftwood.Primitives.NotificationPreference,
      repo: Driftwood.Repo
    ]

    {:ok, _} =
      Samen.Notifications.Engine.notify(
        %{
          org_id: org_id,
          recipient_id: recipient_id,
          event_type: "sla.breach",
          channel: :in_app,
          rendered_body:
            "SLA breached on \"Detention charge dispute — #{spec.prefix}-#{base + 2}\": " <>
              "first response exceeded the 4h target."
        },
        engine_opts
      )

    {:ok, read_notification} =
      Samen.Notifications.Engine.notify(
        %{
          org_id: org_id,
          recipient_id: recipient_id,
          event_type: "invoice.past_due",
          channel: :in_app,
          rendered_body:
            "Invoice for the #{spec.lane} lane subscription is past due — " <>
              "please review Billing → Invoices."
        },
        engine_opts
      )

    {:ok, _} =
      Samen.Notifications.Engine.notify(
        %{
          org_id: org_id,
          recipient_id: recipient_id,
          event_type: "chat.mention",
          channel: :in_app,
          rendered_body:
            "You were mentioned in \"Rate confirmation for load #{spec.prefix}-#{base + 1}\".",
          subject_ref: person && "samen:crm.person:#{person.id}"
        },
        engine_opts
      )

    # Mark ONE read so the inbox shows a read/unread mix (badge = 2, not 3).
    read_notification
    |> Ash.Changeset.for_update(
      :update,
      %{read_at: DateTime.utc_now() |> DateTime.truncate(:second), status: :read},
      authorize?: false
    )
    |> Ash.update!(authorize?: false)

    :ok
  end

  defp tenant_slug(spec) do
    spec.domain |> String.split(".") |> List.first()
  end

  defp first_person(org_id) do
    Driftwood.Crm.Person
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  rescue
    _ -> nil
  end

  defp first_driver(org_id) do
    Driftwood.Freight.Driver
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  rescue
    _ -> nil
  end
end
