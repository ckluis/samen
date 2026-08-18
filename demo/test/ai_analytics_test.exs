defmodule Demo.AiAnalyticsTest do
  @moduledoc """
  T71 (ADR-043 §6.4, D7) — AI analytics over the token-blind AGGREGATE plane, the
  end-to-end proof: real Postgres, real k-anonymity floor (`Demo.Aggregate.MrrByTier`,
  demo config `k: 2`), real fake-provider recording. `Samen.AI.Analytics` lives in
  samen_core (framework-first); this test is the ≈0-LOC vertical exercise — demo authors
  NO new AI wiring, it just calls `Samen.AI.Analytics.ask/4` with its own existing
  aggregate resource (`Demo.AggregatePrivacyFloorsTest`'s exact seeding idiom).

  ## THE CRUX: AGGREGATE NON-LEAK

  A count-of-one MRR tier ("Bespoke", tenant_count 1 < k=2) would, if a naive analytics
  layer bypassed the floor (read raw rows, or called `read_all/2` with
  `suppress: false`), let an operator ask "what is Bespoke's MRR?" and get back ONE
  tenant's exact revenue — a per-record value surfaced under the guise of an aggregate
  (the classic min/max/sample-row/count-of-one leak ADR-043 §6.4 names). `Samen.AI.
  Analytics.ask/4` reads ONLY through `Samen.Aggregate.read_all/2` with the ENFORCED
  defaults (never `suppress: false`), so the count-of-one cell is ALREADY a
  `%Samen.Aggregate.Suppressed{}` — no number to leak — by the time it reaches the AI
  narration input. This test proves the canary revenue value NEVER reaches the fake AI
  provider's recorded payload.

  ## THE POSITIVE CONTROL

  A `>= k` cohort ("Pro", 2 tenants) releases its TRUE total — proving the floor is a
  discriminator (not an always-suppress that would make the RED assertion above vacuous):
  the AI narration input DOES carry the correct Pro total.
  """
  use Demo.DataCase, async: false

  alias Demo.Aggregate.MrrByTier
  alias Samen.AI.{Analytics, Provider}

  setup do
    Provider.Fake.reset()
    :ok
  end

  defp mk_org(name) do
    {:ok, org} =
      Demo.Identity.Org |> Ash.Changeset.for_create(:create, %{name: name}) |> Ash.create(authorize?: false)

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
        unit_amount: Samen.Type.Money.from_cents(cents, :USD),
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
        billing_name: "Bill Payer",
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

  defp one_tenant_on_tier!(tier_name, cents) do
    org = mk_org("Solo-#{System.unique_integer([:positive])}")
    plan = mk_plan(org.id, tier_name)
    mk_price(org.id, plan.id, cents)
    cust = mk_customer(org.id)
    mk_subscription(org.id, cust.id, plan.id)
    org
  end

  defp two_tenants_on_tier!(tier_name, cents) do
    for _ <- 1..2, do: one_tenant_on_tier!(tier_name, cents)
    :ok
  end

  defp scope(org) do
    %Samen.Scope{actor: %{id: Ash.UUID.generate(), org_id: org, role: :member, plane: :operator}}
  end

  defp provider_payload_text do
    Provider.Fake.sent_payloads()
    |> Enum.flat_map(fn {_cb, p} -> Enum.map(p.segments, &to_string/1) end)
    |> Enum.join(" ")
  end

  test "AGGREGATE NON-LEAK: a count-of-one tier's TRUE revenue never reaches the AI narration payload (positive control: the >=k tier's TRUE total IS reported)" do
    # Bespoke: ONE tenant, a canary-distinctive exact revenue (tenant_count 1 < k=2 -> suppressed).
    canary_cents = 777_777
    one_tenant_on_tier!("Bespoke", canary_cents)

    # Pro: TWO tenants at 5000 cents each -> tenant_count 2 >= k=2 -> released, total 10_000.
    two_tenants_on_tier!("Pro", 5000)

    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    org = Ash.UUID.generate()

    assert {:ok, %Samen.AI.Completion{}} =
             Analytics.ask(scope(org), MrrByTier, "What is the MRR for the Bespoke and Pro tiers?")

    payload = provider_payload_text()

    # THE CRUX: the suppressed cohort's TRUE value never reaches the provider.
    refute payload =~ Integer.to_string(canary_cents),
           "the count-of-one Bespoke tier's TRUE revenue leaked into the AI narration payload"

    # The narration input carries the suppression marker for Bespoke instead of a number.
    assert payload =~ Samen.Aggregate.Suppressed.glyph(),
           "a suppressed cell must render the suppression glyph in the AI narration input"

    # POSITIVE CONTROL: the >=k Pro tier's TRUE total (10_000) IS reported — the floor is a
    # discriminator, not an always-suppress that would make the assertion above vacuous.
    assert payload =~ "10000",
           "the >=k Pro tier's correctly-computed total must reach the AI narration input"
  end

  test "SABOTAGE-REFUTABLE MECHANISM: read_all/2's enforced suppress default is what the assertion above depends on" do
    # Direct proof of the mechanism the AI-layer test above exercises indirectly: reading
    # the SAME seeded data with suppress: false (what a sabotaged Analytics.ask/4 would do)
    # DOES surface the count-of-one cell's true value — confirming the RED assertion above
    # is refutable, not a tautology of read_all/2 always suppressing regardless of input.
    canary_cents = 424_242
    one_tenant_on_tier!("Bespoke", canary_cents)
    {:ok, _} = Demo.Aggregate.Rebuild.run(Demo.Repo)

    {:ok, suppressed_rows} = Samen.Aggregate.read_all(MrrByTier)
    bespoke = Enum.find(suppressed_rows, &(&1.tier == "Bespoke"))
    assert Samen.Aggregate.Suppressed.suppressed?(bespoke.mrr_cents)

    {:ok, raw_rows} = Samen.Aggregate.read_all(MrrByTier, suppress: false)
    raw_bespoke = Enum.find(raw_rows, &(&1.tier == "Bespoke"))
    assert raw_bespoke.mrr_cents == canary_cents
  end
end
