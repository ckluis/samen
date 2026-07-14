defmodule Driftwood.CockpitInheritanceTest do
  @moduledoc """
  WS-B / Phase B9 — AC-X1 vertical-inheritance proof, driftwood side.

  Driftwood adopts EVERYTHING WS-B shipped in domain-mount + config + registry rows
  only; the operator-cockpit surfaces themselves are framework LiveViews inherited
  through the ONE existing `samen_operator_routes/2` call at 0 vertical LiveView LOC.

    1. Router — the B3/B4/B6/B8 cockpit routes (`/operator/revenue`,
       `/operator/accounts/:id`, `/operator/flags`, `/operator/analytics`) are
       declared by the macro, not by any Driftwood module.
    2. `mov` — the B1 movement ledger is mounted on BOTH billing namespaces
       (`fbv` tenant / `dpv` operator; landed in B1, re-asserted here).
    3. `fae` — `Samen.Analytics.track/1` writes Driftwood's token-blind
       product-event ledger via the configured emitter (B7 inheritance).
    4. Rollups — the B2/B8 domain-sourced specs (`:revenue_rollup`,
       `:product_event_rollup`) are registered and `Samen.Rollup.refresh/2`
       materializes the host-invariant `mrr_`/`paf_` tables from Driftwood's
       `dpv`/`fae` ledgers.
    5. Flags — the B5 engine fields (`target_rules`/`variants`) exist on the
       mounted `fff` resource and `Samen.FeatureFlags.evaluate/2` runs over it.
  """
  use Driftwood.DataCase, async: false

  alias Driftwood.Analytics.ProductEvent
  alias Samen.{Analytics, FeatureFlags, Rollup}

  require Ash.Query

  setup do
    :ok = Driftwood.Analytics.NonPiiSetup.register_all()
    :ok
  end

  describe "1 — cockpit routes are macro-inherited (0 vertical LiveView LOC)" do
    test "the WS-B operator surfaces are declared on DriftwoodWeb.Router" do
      routes = DriftwoodWeb.Router.__routes__()

      for {path, live_view} <- [
            {"/operator/revenue", Samen.Web.Operator.RevenueLive},
            {"/operator/accounts/:id", Samen.Web.Operator.AccountDetailLive},
            {"/operator/flags", Samen.Web.Operator.FlagAdminLive},
            {"/operator/analytics", Samen.Web.Operator.AnalyticsLive}
          ] do
        route = Enum.find(routes, &(&1.path == path))
        assert route, "expected #{path} to be declared by samen_operator_routes/2"

        # The route renders the FRAMEWORK LiveView (samen_web), not a vertical one.
        {mounted_lv, _, _, _} = route.metadata.phoenix_live_view
        assert mounted_lv == live_view
      end
    end

    test "no Driftwood-authored WS-B cockpit LiveView module exists" do
      # (`DriftwoodWeb.OperatorImpersonationLive` is the pre-WS-B T4.1 masked
      # impersonation surface — vertical by design, not a WS-B cockpit page.)
      {:ok, mods} = :application.get_key(:driftwood, :modules)

      refute Enum.any?(mods, fn m ->
               name = Atom.to_string(m)

               String.ends_with?(name, "Live") and
                 String.contains?(name, [
                   "Revenue",
                   "AccountDetail",
                   "FlagAdmin",
                   "Analytics",
                   "PlatformBilling"
                 ])
             end),
             "AC-X1: the WS-B cockpit surfaces must be inherited, not vertical-authored"
    end
  end

  describe "2 — mov ledger mounted on both billing namespaces (B1)" do
    test "fbv + dpv subscription-event resources exist with fresh abbrevs" do
      assert Ash.Resource.Info.resource?(Driftwood.Billing.SubscriptionEvent)
      assert Ash.Resource.Info.resource?(Driftwood.Operator.SubscriptionEvent)

      assert "fbv_subscription_event" ==
               AshPostgres.DataLayer.Info.table(Driftwood.Billing.SubscriptionEvent)

      assert "dpv_subscription_event" ==
               AshPostgres.DataLayer.Info.table(Driftwood.Operator.SubscriptionEvent)
    end
  end

  describe "3 — fae product-event capture (B7 inheritance)" do
    test "track/1 writes exactly one bounded fae row via the configured emitter" do
      org_id = Ash.UUID.generate()

      assert {:ok, %ProductEvent{} = fae} =
               Analytics.track(%{
                 org_id: org_id,
                 event_name: "record.created",
                 entity_ref: "load-42",
                 props: %{"resource" => "freight.load"}
               })

      assert fae.event_name == :"record.created"
      assert fae.event_kind == :record

      rows =
        ProductEvent
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 1
      assert AshPostgres.DataLayer.Info.table(ProductEvent) == "fae_product_event"
    end

    test "a PII-bearing prop value is refused at capture (never persisted)" do
      org_id = Ash.UUID.generate()

      assert {:error, _} =
               Analytics.track(%{
                 org_id: org_id,
                 event_name: "record.created",
                 props: %{"resource" => "dispatcher@blueridge.example"}
               })

      assert [] ==
               ProductEvent
               |> Ash.Query.filter(org_id == ^org_id)
               |> Ash.read!(authorize?: false)
    end
  end

  describe "4 — domain-sourced cockpit rollups (B2/B8 inheritance)" do
    test "both specs are registered and refresh materializes the host-invariant tables" do
      specs = Rollup.specs()
      names = Enum.map(specs, & &1.name)
      assert :revenue_rollup in names
      assert :product_event_rollup in names

      revenue = Enum.find(specs, &(&1.name == :revenue_rollup))
      assert revenue.source == :domain
      assert revenue.table == "mrr_revenue_rollup"
      assert revenue.domain_table == "dpv_subscription_event"

      # Seed one operator-book movement, refresh, read the rollup to the cent.
      org_id = Ash.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Driftwood.Repo.query!(
        """
        INSERT INTO dpv_subscription_event
          (dpv_subscription_id, dpv_kind, dpv_mrr_delta_cents, dpv_mrr_before_cents,
           dpv_mrr_after_cents, dpv_occurred_at, dpv_org_id, dpv_inserted_at, dpv_updated_at)
        VALUES ($1, 'new', 4900, 0, 4900, $2, $3, $2, $2)
        """,
        [Ecto.UUID.dump!(Ash.UUID.generate()), now, Ecto.UUID.dump!(org_id)]
      )

      assert {:ok, _} = Rollup.refresh(Driftwood.Repo, revenue)

      %{rows: [[delta, count]]} =
        Driftwood.Repo.query!(
          "SELECT mrr_delta_cents, mrr_count FROM mrr_revenue_rollup WHERE mrr_org_id = $1",
          [Ecto.UUID.dump!(org_id)]
        )

      assert delta == 4900
      assert count == 1

      # The paf rollup refreshes over the fae ledger (funnel arm).
      {:ok, _} =
        Analytics.track(%{org_id: org_id, event_name: "first_run.completed", props: %{}})

      paf = Enum.find(specs, &(&1.name == :product_event_rollup))
      assert paf.domain_table == "fae_product_event"
      assert {:ok, _} = Rollup.refresh(Driftwood.Repo, paf)

      %{rows: rows} =
        Driftwood.Repo.query!(
          "SELECT paf_stage FROM paf_product_event_rollup WHERE paf_org_id = $1 AND paf_kind = 'funnel'",
          [Ecto.UUID.dump!(org_id)]
        )

      assert ["first_run"] == Enum.map(rows, fn [stage] -> stage end)
    end
  end

  describe "5 — flag engine fields on the mounted fff resource (B5 inheritance)" do
    test "target_rules/variants exist physically and the engine runs over an fff row" do
      flag_resource = Driftwood.Primitives.FeatureFlag
      assert Ash.Resource.Info.attribute(flag_resource, :target_rules)
      assert Ash.Resource.Info.attribute(flag_resource, :variants)
      assert AshPostgres.DataLayer.Info.table(flag_resource) == "fff_feature_flag"

      org_id = Ash.UUID.generate()

      # Persist a flag row (the physical columns exist — the B5 fields migration),
      # then run the kernel precedence pipeline over its config (the B6 admin path).
      flag =
        Ash.Seed.seed!(flag_resource, %{
          name: "b9.inheritance_smoke",
          enabled: true,
          rollout_pct: 100,
          target_rules: [%{"attr" => "plan", "op" => "eq", "value" => "pro", "then" => "allow"}],
          variants: %{},
          org_id: org_id
        })

      assert flag.target_rules != []

      decision =
        FeatureFlags.evaluate_config(
          "b9.inheritance_smoke",
          %{enabled: flag.enabled, rollout_pct: flag.rollout_pct, target_rules: []},
          %{org_id: org_id}
        )

      assert %Samen.FeatureFlags.Decision{on: true} = decision
    end
  end
end
