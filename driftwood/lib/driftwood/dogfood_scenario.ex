defmodule Driftwood.DogfoodScenario do
  @moduledoc """
  The scripted end-to-end DOGFOOD scenario (T5.3 clause (c)) — the single source of
  truth for the walkthrough, driven by BOTH the dev seed (`Driftwood.Seeds` / the dev
  server) and the dogfood test (`test/dogfood_walkthrough_test.exs`).

  `build/1` creates, for a brokerage tenant org:

    * two brokerage TENANT companies (this dogfood seeds TWO orgs so the cross-tenant
      aggregate plane has >1 tenant per cohort — see `build_fleet/0`);
    * per org: a CARRIER + a SHIPPER (Company rows, role in the `company_role` custom
      field), each carrying a `plan_tier` + `mrr_cents` on the Carrier for the MRR
      aggregate;
    * DRIVERS — a fully-compliant one (dispatchable) AND an expired-medical-card one
      (FMCSA-blocked), each with a vaulted CDL number;
    * LOADS (Opportunity alias) with a `lane` custom field for the load-volume aggregate;
    * a DISPATCH of the compliant driver onto a load (the FMCSA gate passes);
    * a SETTLEMENT (linehaul/advances/factoring/claims) — the reshaped money;
    * the tenant-plane broker rollup (`Driftwood.BrokerRollup.run/2`) and the
      cross-tenant aggregate projections (`Driftwood.Aggregate.Rebuild.run/1`).

  It returns a map of the created ids so the test can assert against them.
  """

  @doc """
  Build the FULL fleet: two brokerage orgs, each fully populated, plus the rebuilt
  rollups + aggregates. Returns `%{orgs: [%{...}, %{...}]}`.
  """
  def build_fleet(repo \\ Driftwood.Repo) do
    :ok = Driftwood.NonPiiSetup.register_all()

    org_a = build(org_id: uuid(), tier: "growth", mrr_cents: 250_000, lane: "TX->CA")
    org_b = build(org_id: uuid(), tier: "growth", mrr_cents: 300_000, lane: "TX->CA")

    # Rebuild the cross-tenant aggregate projections once, spanning both orgs.
    {:ok, agg} = Driftwood.Aggregate.Rebuild.run(repo)

    %{orgs: [org_a, org_b], aggregate: agg}
  end

  @doc """
  Build ONE brokerage tenant org's full scenario. Options: `:org_id`, `:tier`,
  `:mrr_cents`, `:lane`. Returns a map of created ids + the broker rollup result.
  """
  def build(opts \\ []) do
    org_id = Keyword.get(opts, :org_id, uuid())
    tier = Keyword.get(opts, :tier, "growth")
    mrr_cents = Keyword.get(opts, :mrr_cents, 250_000)
    lane = Keyword.get(opts, :lane, "TX->CA")

    # Per-tenant BRANDING (defaults preserve the historical Blue-Ridge scenario for the no-option
    # test callers; the dev seed passes the spec's own carrier/shipper/lane so each tenant's
    # freight fleet reads as ITS OWN book — not a Blue-Ridge clone).
    carrier_name = Keyword.get(opts, :carrier, "Blue Ridge Carriers")
    shipper_name = Keyword.get(opts, :shipper, "Acme Manufacturing")
    origin = Keyword.get(opts, :origin, "Dallas")
    dest = Keyword.get(opts, :dest, "Los Angeles")
    equipment = Keyword.get(opts, :equipment, "dry van")
    prefix = Keyword.get(opts, :prefix, "BR")

    :ok = Driftwood.NonPiiSetup.register_all()

    actor = %{org_id: org_id, role: :admin}

    # Define the Tier-1 custom fields this scenario writes (T3.8: a custom-bag value is
    # rejected unless a `tnt_field` definition exists). company_role/plan_tier/mrr_cents
    # ride the Company (Carrier) bag; lane rides the Load (Opportunity) bag. All non-PII.
    :ok = define_custom_fields(org_id)

    # Seed the Tier-0 load-lifecycle stages for this org.
    :ok = seed_pipeline(org_id, actor)

    carrier = create_company(org_id, carrier_name, %{
      "company_role" => "carrier",
      "plan_tier" => tier,
      "mrr_cents" => Integer.to_string(mrr_cents)
    })

    shipper = create_company(org_id, shipper_name, %{"company_role" => "shipper"})

    compliant = create_driver(org_id, carrier.id, "Dana", "Compliant", "CDL-OK-#{short()}",
      cdl_expiry_days: 365, medical_days: 180, status: :available)

    # EXPIRING (task: valid/expiring/expired FMCSA) — medical card valid but expiring in 14 days.
    # Still DISPATCHABLE (the gate blocks only on `< today`) but the driver board flags it amber.
    _expiring = create_driver(org_id, carrier.id, "Casey", "Expiring", "CDL-EXP14-#{short()}",
      cdl_expiry_days: 45, medical_days: 14, status: :available)

    blocked = create_driver(org_id, carrier.id, "Reed", "Expired", "CDL-EXP-#{short()}",
      cdl_expiry_days: 365, medical_days: -3, status: :available)

    load1 = create_load(org_id, "#{prefix}-9001 #{origin} -> #{dest} #{equipment}", 480_000, lane, :open)
    load2 = create_load(org_id, "#{prefix}-9002 #{origin} -> #{dest} #{equipment}", 620_000, lane, :open)

    # Dispatch the compliant driver onto load1 (the FMCSA gate passes).
    {:ok, dispatch} = dispatch(org_id, compliant.id, load1.id)

    settlement = create_settlement(org_id, carrier.id, load1.id,
      linehaul: 480_000, advances: 50_000, fuel: 30_000, accessorial: 10_000,
      claims: 5_000, factoring_bps: 300)

    # Rebuild the tenant-plane broker summary rollup for this org.
    {:ok, rollup} = Driftwood.BrokerRollup.run(org_id)

    %{
      org_id: org_id,
      carrier_id: carrier.id,
      shipper_id: shipper.id,
      compliant_driver_id: compliant.id,
      blocked_driver_id: blocked.id,
      load1_id: load1.id,
      load2_id: load2.id,
      dispatch_id: dispatch.id,
      settlement_id: settlement.id,
      tier: tier,
      mrr_cents: mrr_cents,
      lane: lane,
      rollup: rollup
    }
  end

  # -- builders (all authorize?: false — this is a seed/dogfood harness) ------

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

  defp seed_pipeline(org_id, actor) do
    Enum.each(Driftwood.Seeds.load_stages(), fn stage ->
      Driftwood.Crm.Pipeline
      |> Ash.Changeset.for_create(:create, Map.put(stage, :org_id, org_id),
        actor: actor, authorize?: false)
      |> Ash.create!()
    end)

    :ok
  end

  defp create_company(org_id, name, custom) do
    Driftwood.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name, custom: custom},
      authorize?: false)
    |> Ash.create!()
  end

  defp create_driver(org_id, carrier_id, first, last, cdl, kw) do
    Driftwood.Freight.Driver
    |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        carrier_id: carrier_id,
        full_name: %{first: first, last: last},
        cdl_number: cdl,
        cdl_state: "TX",
        cdl_expiry: Date.utc_today() |> Date.add(kw[:cdl_expiry_days]) |> Date.to_iso8601(),
        medical_card_expiry: Date.add(Date.utc_today(), kw[:medical_days]),
        eld_provider: :samsara,
        status: kw[:status]
      }, authorize?: false)
    |> Ash.create!()
  end

  defp create_load(org_id, name, value_cents, lane, status) do
    Driftwood.Crm.Opportunity
    |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        name: name,
        value_cents: value_cents,
        status: status,
        custom: %{"lane" => lane}
      }, authorize?: false)
    |> Ash.create!()
  end

  defp dispatch(org_id, driver_id, load_id) do
    Driftwood.Freight.DispatchEvent
    |> Ash.Changeset.for_create(:dispatch, %{driver_id: driver_id, load_id: load_id},
      actor: %{org_id: org_id, role: :member}, authorize?: true)
    |> Ash.create()
  end

  defp create_settlement(org_id, carrier_id, load_id, kw) do
    Driftwood.Freight.Settlement
    |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        carrier_id: carrier_id,
        load_id: load_id,
        linehaul_cents: kw[:linehaul],
        advances_cents: kw[:advances],
        fuel_surcharge_cents: kw[:fuel],
        accessorial_cents: kw[:accessorial],
        claim_deduction_cents: kw[:claims],
        factoring_rate_bps: kw[:factoring_bps],
        status: :approved
      }, authorize?: false)
    |> Ash.create!()
  end

  defp uuid, do: Ecto.UUID.generate()
  defp short, do: :erlang.unique_integer([:positive]) |> Integer.to_string()
end
