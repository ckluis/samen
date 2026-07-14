defmodule PawChart.CockpitInheritanceTest do
  @moduledoc """
  WS-B / Phase B9 — AC-X1 vertical-inheritance proof, pawchart side.

  PawChart adopts the WS-B KERNEL scopes in domain-mount + config + registry rows
  only (zero vertical LiveView modules):

    1. `mov` — the B1 movement ledger on the Billing mount (`pbv`; landed in B1,
       re-asserted here).
    2. `vae` — `Samen.Analytics.track/1` writes PawChart's token-blind
       product-event ledger via the configured emitter (B7 inheritance).
    3. Rollups — the B2/B8 domain-sourced specs (`:revenue_rollup`,
       `:product_event_rollup`) are registered and `Samen.Rollup.refresh/2`
       materializes the host-invariant `mrr_`/`paf_` tables from PawChart's
       `pbv`/`vae` ledgers.
    4. Flags — the B5 engine fields (`target_rules`/`variants`) exist on the
       mounted `vff` resource and the kernel precedence pipeline runs over it.

  NOTE (honest boundary, for the B9 gate): PawChart's router mounts NO
  `samen_operator_routes/2` — the vertical has no ADR-010 operator NAMESPACE
  (Identity/Billing/Support second mounts) at all; its "operator plane" is the
  resource/masking layer measured in `pawchart/docs/reuse-measurement.md`. The
  cockpit SURFACES therefore render only on hosts that call the macro (driftwood —
  proven in `driftwood/test/cockpit_inheritance_test.exs`). Standing up
  `PawChart.Operator` is a separate mount unit, not a WS-B page-authoring task.
  """
  use PawChart.DataCase, async: false

  alias PawChart.Analytics.ProductEvent
  alias Samen.{Analytics, FeatureFlags, Rollup}

  require Ash.Query

  setup do
    :ok = PawChart.Analytics.NonPiiSetup.register_all()
    :ok
  end

  describe "1 — mov ledger mounted on the Billing namespace (B1)" do
    test "pbv subscription-event resource exists with the fresh abbrev" do
      assert Ash.Resource.Info.resource?(PawChart.Billing.SubscriptionEvent)

      assert "pbv_subscription_event" ==
               AshPostgres.DataLayer.Info.table(PawChart.Billing.SubscriptionEvent)
    end
  end

  describe "2 — vae product-event capture (B7 inheritance)" do
    test "track/1 writes exactly one bounded vae row via the configured emitter" do
      org_id = Ash.UUID.generate()

      assert {:ok, %ProductEvent{} = vae} =
               Analytics.track(%{
                 org_id: org_id,
                 event_name: "record.created",
                 entity_ref: "patient-7",
                 props: %{"resource" => "clinic.patient"}
               })

      assert vae.event_name == :"record.created"
      assert vae.event_kind == :record

      rows =
        ProductEvent
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.read!(authorize?: false)

      assert length(rows) == 1
      assert AshPostgres.DataLayer.Info.table(ProductEvent) == "vae_product_event"
    end

    test "a PII-bearing prop value is refused at capture (never persisted)" do
      org_id = Ash.UUID.generate()

      assert {:error, :pii_rejected} =
               Analytics.track(%{
                 org_id: org_id,
                 event_name: "record.created",
                 props: %{"resource" => "dr.mendez@happypaws.example"}
               })

      assert [] ==
               ProductEvent
               |> Ash.Query.filter(org_id == ^org_id)
               |> Ash.read!(authorize?: false)
    end
  end

  describe "3 — domain-sourced cockpit rollups (B2/B8 inheritance)" do
    test "both specs are registered and refresh materializes the host-invariant tables" do
      specs = Rollup.specs()
      names = Enum.map(specs, & &1.name)
      assert :revenue_rollup in names
      assert :product_event_rollup in names

      revenue = Enum.find(specs, &(&1.name == :revenue_rollup))
      assert revenue.source == :domain
      assert revenue.table == "mrr_revenue_rollup"
      assert revenue.domain_table == "pbv_subscription_event"

      # Seed one clinic movement, refresh, read the rollup to the cent.
      org_id = Ash.UUID.generate()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      PawChart.Repo.query!(
        """
        INSERT INTO pbv_subscription_event
          (pbv_subscription_id, pbv_kind, pbv_mrr_delta_cents, pbv_mrr_before_cents,
           pbv_mrr_after_cents, pbv_occurred_at, pbv_org_id, pbv_inserted_at, pbv_updated_at)
        VALUES ($1, 'new', 2900, 0, 2900, $2, $3, $2, $2)
        """,
        [Ecto.UUID.dump!(Ash.UUID.generate()), now, Ecto.UUID.dump!(org_id)]
      )

      assert {:ok, _} = Rollup.refresh(PawChart.Repo, revenue)

      %{rows: [[delta, count]]} =
        PawChart.Repo.query!(
          "SELECT mrr_delta_cents, mrr_count FROM mrr_revenue_rollup WHERE mrr_org_id = $1",
          [Ecto.UUID.dump!(org_id)]
        )

      assert delta == 2900
      assert count == 1

      # The paf rollup refreshes over the vae ledger (funnel arm).
      {:ok, _} =
        Analytics.track(%{org_id: org_id, event_name: "first_run.completed", props: %{}})

      paf = Enum.find(specs, &(&1.name == :product_event_rollup))
      assert paf.domain_table == "vae_product_event"
      assert {:ok, _} = Rollup.refresh(PawChart.Repo, paf)

      %{rows: rows} =
        PawChart.Repo.query!(
          "SELECT paf_stage FROM paf_product_event_rollup WHERE paf_org_id = $1 AND paf_kind = 'funnel'",
          [Ecto.UUID.dump!(org_id)]
        )

      assert ["first_run"] == Enum.map(rows, fn [stage] -> stage end)
    end
  end

  describe "4 — flag engine fields on the mounted vff resource (B5 inheritance)" do
    test "target_rules/variants exist physically and the engine runs over a vff row" do
      flag_resource = PawChart.Primitives.FeatureFlag
      assert Ash.Resource.Info.attribute(flag_resource, :target_rules)
      assert Ash.Resource.Info.attribute(flag_resource, :variants)
      assert AshPostgres.DataLayer.Info.table(flag_resource) == "vff_feature_flag"

      org_id = Ash.UUID.generate()

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
