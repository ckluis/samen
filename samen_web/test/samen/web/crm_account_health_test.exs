defmodule Samen.Web.CRMAccountHealthTest do
  @moduledoc """
  T77 (spec §I4 "unfair advantage") — live MRR / health / support inline on CRM
  accounts. Proofs, per CLAUDE.md's masking watch-list + anti-tautology discipline:

    * DETERMINISTIC METRICS (pure formula) — `Samen.Web.AccountHealth.score/1`'s
      composite/band arithmetic matches hand-computed expected values EXACTLY, no DB.
    * WIRING (done-criterion 1) — `AccountHealth.snapshot/2`, run over a REAL seeded
      subscription/invoice/tickets, produces the SAME hand-computed MRR/support-load/
      health figures — the number is born from the substrate, not hand-entered.
    * DUNNING CEILING — a subscription with a maximally-overdue invoice caps the
      billing factor's value below its top band; proven end-to-end through real reads.
    * HONEST ABSENCE — a mount whose host root has no Billing/Support sibling gets
      `_available?: false` and `nil` figures (never a fabricated `$0.00`/`0`); a
      MOUNTED-but-empty org gets a REAL zero (a true DB aggregate, not a fabrication).
    * ORG-SCOPE (sabotage-refutable, the T74/T75/T76 lesson) — org B's subscription/
      tickets NEVER contribute to org A's snapshot (and DO contribute to org B's own).
    * MASKING (verified non-PII, refutable) — every field this surface reads is NOT
      vault-routed, anchored against real 🔒 fields on the SAME resources
      (`Customer.billing_name`, `Message.body`) — this surface never calls
      `Samen.Api.PiiResolution.resolve/4`/`Samen.Vault.reveal/3`.
    * FIRST-CLIENT — the real `CompanyLive` renders the panel from seeded data, and
      honestly-empty for a fresh org.

  ## Fix round 1 (independent verdict PARTIAL, design call refuted on the facts)

  Added this round, per the delta verdict:

    * WORST-OF-N (MED-2) — an org with an active subscription AND a sibling past-due
      one must show the WORST state, never cherry-pick the best "primary" one; pinned
      both as a real DB wiring proof and (via sabotage 86) as a refutable guarantee.
    * DEGRADED READ != ZERO (MED-3) — a genuinely FAILED read (not "truly empty") must
      surface honest absence, never a fabricated `$0`/`0`; pinned (via sabotage 87).
    * COPY HONESTY (HIGH) — the panel is a PORTFOLIO view across this org's ENTIRE own
      customer/support book, not "this org's relationship with the platform" and not
      this specific company's numbers; tile labels/disclosure say so explicitly.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.AccountHealth
  alias Samen.Web.CRM.CompanyLive

  # ==========================================================================
  # Seed helpers
  # ==========================================================================

  defp seed_subscription(org_id, opts) do
    status = Keyword.get(opts, :status, :active)
    amount_cents = Keyword.get(opts, :amount_cents, 19_900)

    plan =
      Samen.WebTest.Billing.Plan
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, name: "plan-#{System.unique_integer([:positive])}", interval: :monthly, enabled: true},
        actor: %{org_id: org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    _price =
      Samen.WebTest.Billing.Price
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          plan_id: plan.id,
          unit_amount: Samen.Type.Money.from_cents(amount_cents, :USD),
          interval: :monthly,
          active: true
        },
        actor: %{org_id: org_id, role: :admin},
        authorize?: false
      )
      |> Ash.create!()

    customer =
      Samen.WebTest.Billing.Customer
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          billing_name: "Health Fixture Holdings #{System.unique_integer([:positive])}",
          billing_email: "billing-#{System.unique_integer([:positive])}@example.com",
          status: :active,
          currency: "USD"
        },
        authorize?: false
      )
      |> Ash.create!()

    subscription =
      Samen.WebTest.Billing.Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, customer_id: customer.id, plan_id: plan.id, status: status},
        actor: %{org_id: org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    %{plan: plan, customer: customer, subscription: subscription}
  end

  defp seed_invoice(org_id, customer_id, subscription_id, opts) do
    Samen.WebTest.Billing.Invoice
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org_id,
          customer_id: customer_id,
          subscription_id: subscription_id,
          status: :open,
          amount_due_cents: 5_000,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), 14 * 86_400, :second)
        },
        Map.new(opts)
      ),
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_ticket(org_id, opts) do
    Samen.WebTest.Support.Ticket
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{org_id: org_id, subject: "issue-#{System.unique_integer([:positive])}", status: :open, priority: :normal},
        Map.new(opts)
      ),
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_company(org_id, name \\ "Acme Freight Co") do
    Samen.WebTest.Crm.Company
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: name}, authorize?: false)
    |> Ash.create!()
  end

  # ==========================================================================
  # 1. DETERMINISTIC METRICS — pure `score/1`, no DB
  # ==========================================================================

  test "score/1: both scopes absent (nil) => composite is nil/:unknown, no fabricated number" do
    breakdown = AccountHealth.score(%{billing: nil, support: nil})

    assert breakdown.score == nil
    assert breakdown.band == :unknown
    assert Enum.all?(breakdown.factors, &(&1.value == :unknown))
  end

  test "score/1: ANTI-TAUTOLOGY — a fabricated-zero implementation would NOT equal nil" do
    breakdown = AccountHealth.score(%{billing: nil, support: nil})
    refute breakdown.score === 0
  end

  test "score/1: only billing known => support :unknown renormalizes, weight fully on billing" do
    breakdown =
      AccountHealth.score(%{
        billing: %{subscription_status: :active, past_due: %{count: 0, amount_cents: 0, max_days_overdue: 0}},
        support: nil
      })

    assert breakdown.score == 100
    assert breakdown.band == :healthy
    support = Enum.find(breakdown.factors, &(&1.name == :support))
    assert support.value == :unknown
    assert support.contribution == 0.0
  end

  test "score/1: DUNNING CEILING caps the billing value even at max cap-eligible overdue age" do
    breakdown =
      AccountHealth.score(%{
        billing: %{subscription_status: :active, past_due: %{count: 1, amount_cents: 5_000, max_days_overdue: 90}},
        support: %{open_tickets: 0, breaching_sla: 0}
      })

    billing = Enum.find(breakdown.factors, &(&1.name == :billing))
    # (0.5 cap) - (90/90 * 0.35) - (0 count penalty) = 0.15 exactly.
    assert_in_delta billing.value, 0.15, 1.0e-9
    assert AccountHealth.factor_band(billing) == :critical
    # billing 0.15*60=9.0, support 1.0*40=40.0 => 49 exactly.
    assert breakdown.score == 49
    assert breakdown.band == :at_risk
  end

  test "score/1: HONEST EMPTY billing (scope mounted, no subscription) is a REAL 0.0, not :unknown" do
    breakdown =
      AccountHealth.score(%{
        billing: %{subscription_status: nil, past_due: %{count: 0, amount_cents: 0, max_days_overdue: 0}},
        support: %{open_tickets: 0, breaching_sla: 0}
      })

    billing = Enum.find(breakdown.factors, &(&1.name == :billing))
    assert billing.value == 0.0
    refute billing.value == :unknown
    assert breakdown.score == 40
    assert breakdown.band == :at_risk
  end

  # ==========================================================================
  # 2. WIRING — real seeded subscription/invoice/tickets through `snapshot/2`
  # ==========================================================================

  test "snapshot/2: seeded subscription -> MRR figure EXACT; open tickets -> support-load count EXACT" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    seed_subscription(org_id, amount_cents: 19_900, status: :active)
    seed_ticket(org_id, status: :open, breached: true)
    seed_ticket(org_id, status: :open, breached: false)

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    assert snap.billing_available? == true
    assert snap.mrr_cents == 19_900
    assert snap.active_subs == 1
    assert snap.subscription_status == :active

    assert snap.support_available? == true
    assert snap.open_tickets == 2
    assert snap.breaching_sla == 1

    # billing: active, no dunning => 1.0 * 60 = 60.0; support: 1 - 0.1*2 - 0.2*1 = 0.6 * 40 = 24.0
    assert snap.health.score == 84
    assert snap.health.band == :watch
  end

  test "snapshot/2: HONEST EMPTY (scopes mounted, org has NOTHING yet) => real zeros, not absence" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    assert snap.billing_available? == true
    assert snap.mrr_cents == 0
    assert snap.subscription_status == nil

    assert snap.support_available? == true
    assert snap.open_tickets == 0
    assert snap.breaching_sla == 0

    # billing: no subscription => 0.0 * 60 = 0.0; support: no tickets => 1.0 * 40 = 40.0
    assert snap.health.score == 40
    assert snap.health.band == :at_risk
  end

  test "snapshot/2: DUNNING wiring — a real past-due invoice caps the billing dimension end-to-end" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    %{customer: customer, subscription: sub} = seed_subscription(org_id, status: :active)
    seed_invoice(org_id, customer.id, sub.id, due_date: DateTime.add(DateTime.utc_now(), -90 * 86_400, :second))

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    assert snap.past_due.count == 1
    assert snap.past_due.amount_cents == 5_000
    assert snap.past_due.max_days_overdue == 90

    billing = Enum.find(snap.health.factors, &(&1.name == :billing))
    assert_in_delta billing.value, 0.15, 1.0e-9
    # billing 0.15*60=9.0, support (no tickets) 1.0*40=40.0 => 49.
    assert snap.health.score == 49
    assert snap.health.band == :at_risk
  end

  # ==========================================================================
  # 3. HONEST ABSENCE — the scope is not mounted for this host AT ALL
  # ==========================================================================

  test "snapshot/2: a host with NO Billing/Support siblings gets honest absence, never a fabricated $0/0" do
    fake_mount =
      Samen.Web.Mount.new(:crm, Module.concat([NoSuchHostForAccountHealthTest, Crm]), Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant()
      )

    org_id = Ash.UUID.generate()
    scope = Samen.Web.Mount.scope(fake_mount, org_id)
    snap = AccountHealth.snapshot(fake_mount, scope)

    assert snap.billing_available? == false
    assert snap.mrr_cents == nil
    assert snap.active_subs == nil
    assert snap.subscription_status == nil
    assert snap.past_due == nil

    assert snap.support_available? == false
    assert snap.open_tickets == nil
    assert snap.breaching_sla == nil

    assert snap.health.score == nil
    assert snap.health.band == :unknown
  end

  test "ANTI-TAUTOLOGY: honest absence is real — the SAME namespace bridge finds the REAL test host's Billing/Support" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    # Proves the honest-absence test above is a real property of the fake host, not a
    # bug that reports "unavailable" for every host.
    assert snap.billing_available? == true
    assert snap.support_available? == true
  end

  # ==========================================================================
  # 4. ORG-SCOPE (sabotage-refutable pin, day one)
  # ==========================================================================

  test "ORG-SCOPE: org B's subscription/tickets never contribute to org A's snapshot (and DO contribute to org B's own)" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    seed_subscription(org_a, amount_cents: 10_000, status: :active)
    seed_ticket(org_a, status: :open)

    # Org B genuinely holds a DIFFERENT, larger subscription + more tickets — the
    # refutation setup (a seed that never landed anywhere would trivially pass).
    seed_subscription(org_b, amount_cents: 50_000, status: :active)
    for _ <- 1..3, do: seed_ticket(org_b, status: :open, breached: true)

    scope_a = Samen.Web.Mount.scope(mount, org_a)
    scope_b = Samen.Web.Mount.scope(mount, org_b)

    snap_a = AccountHealth.snapshot(mount, scope_a)
    snap_b = AccountHealth.snapshot(mount, scope_b)

    assert snap_a.mrr_cents == 10_000
    assert snap_a.open_tickets == 1
    refute snap_a.mrr_cents == 50_000
    refute snap_a.open_tickets == 3

    # Refutation control: org B's OWN snapshot shows its real, different numbers.
    assert snap_b.mrr_cents == 50_000
    assert snap_b.open_tickets == 3
    assert snap_b.breaching_sla == 3
  end

  # ==========================================================================
  # 5. MASKING (verified non-PII, refutable)
  # ==========================================================================

  test "MASKING: every field this surface reads is NOT vault-routed (anchored vs real 🔒 fields on the SAME resources)" do
    assert Samen.Pii.Info.vault_routed?(Samen.WebTest.Billing.Customer, :billing_name)
    assert Samen.Pii.Info.vault_routed?(Samen.WebTest.Support.Message, :body)

    refute Samen.Pii.Info.vault_routed?(Samen.WebTest.Billing.Subscription, :status)
    refute Samen.Pii.Info.vault_routed?(Samen.WebTest.Billing.Invoice, :amount_due_cents)
    refute Samen.Pii.Info.vault_routed?(Samen.WebTest.Billing.Invoice, :due_date)
    refute Samen.Pii.Info.vault_routed?(Samen.WebTest.Billing.Invoice, :status)
    refute Samen.Pii.Info.vault_routed?(Samen.WebTest.Support.Ticket, :status)
    refute Samen.Pii.Info.vault_routed?(Samen.WebTest.Support.Ticket, :breached)
    refute Samen.Pii.Info.vault_routed?(Samen.WebTest.Support.Ticket, :priority)
  end

  test "MASKING: Samen.Web.AccountHealth never calls PiiResolution.resolve/Vault.reveal — nothing to resolve" do
    src = File.read!("lib/samen/web/account_health.ex")
    refute src =~ "PiiResolution.resolve"
    refute src =~ "Vault.reveal"
  end

  # ==========================================================================
  # 6. FIRST-CLIENT — CompanyLive renders the panel from seeded data
  # ==========================================================================

  test "FIRST-CLIENT: CompanyLive renders MRR / account health / open-support-ticket tiles from seeded data" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id)

    seed_subscription(org_id, amount_cents: 19_900, status: :active)
    seed_ticket(org_id, status: :open, breached: true)
    seed_ticket(org_id, status: :open, breached: false)

    html = render_live(CompanyLive, mount, [org_id, company.id])

    assert html =~ "account-health-panel"
    assert html =~ "account-mrr"
    assert html =~ "$199.00"
    assert html =~ "account-health-score"
    assert html =~ "84 / 100"
    assert html =~ "watch"
    assert html =~ "account-support-load"
    assert html =~ "1 breaching SLA"
  end

  test "FIRST-CLIENT HONEST EMPTY: a fresh org renders real zeros — never a fabricated MRR/health/ticket number" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Fresh Co")

    html = render_live(CompanyLive, mount, [org_id, company.id])

    assert html =~ "account-health-panel"
    # Rendered via an interpolated `{@sub}` expression (unlike the static disclosure
    # text below), so Phoenix.HTML escapes the apostrophe to `&#39;`.
    assert html =~ "no subscriptions on file across this org&#39;s customers"
    assert html =~ "40 / 100"
    assert html =~ "at risk"
    assert html =~ "none breaching SLA"
  end

  # ==========================================================================
  # 7. Fix round 1, HIGH — COPY HONESTY: portfolio totals, never this company's own
  # ==========================================================================

  test "FIRST-CLIENT COPY HONESTY (fix round 1, HIGH): tiles/disclosure read as portfolio-wide totals, never this company's own numbers" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id)

    seed_subscription(org_id, amount_cents: 19_900, status: :active)

    html = render_live(CompanyLive, mount, [org_id, company.id])

    # The corrected, honest labels/disclosure.
    assert html =~ "Total MRR — all customers"
    assert html =~ "Portfolio health"
    assert html =~ "Open support tickets — all customers"
    assert html =~ "org-wide totals across this org's ENTIRE customer &amp; support book"
    assert html =~ "NOT this specific company's numbers"
    assert html =~ "CRM-account-to-billing-customer link the substrate does not have yet"

    # The REFUTED false claims (fix round 1) must never reappear: this is NOT "the
    # org's own relationship with the platform" copy.
    refute html =~ "own billing &amp; support relationship with the platform"
    refute html =~ "relationship with the platform"
  end

  # ==========================================================================
  # 8. Fix round 1, MED-2 — WORST-OF-N: a sibling past-due subscription is never hidden
  #    behind a cherry-picked "primary" (best) one
  # ==========================================================================

  test "snapshot/2 WORST-OF-N (fix round 1, MED-2): an active sub + a sibling past_due sub reports the WORST status, never the best one" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    # Two INDEPENDENT subscriptions (different plan/price/customer each) under the SAME
    # org — one healthy, one genuinely past_due. A prior version preferred the active
    # one as "primary" and reported the WHOLE book as current — literally false.
    seed_subscription(org_id, amount_cents: 10_000, status: :active)
    seed_subscription(org_id, amount_cents: 20_000, status: :past_due)

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    # MRR only counts the genuinely ACTIVE subscription (real DB aggregate — the
    # past_due one contributes nothing, which is correct and unrelated to this bug).
    assert snap.mrr_cents == 10_000
    # The WORST status wins — never "active" just because it happens to sort first.
    assert snap.subscription_status == :past_due

    billing = Enum.find(snap.health.factors, &(&1.name == :billing))
    # dunning (status-only, no invoice evidence yet: 0 count/0 days) => cap with zero
    # penalties = 0.5 exactly.
    assert_in_delta billing.value, 0.5, 1.0e-9
    refute billing.explanation =~ "no past-due invoices anywhere in the book"
    assert billing.explanation =~ "dunning"

    # billing 0.5*60=30.0, support (no tickets) 1.0*40=40.0 => 70.
    assert snap.health.score == 70
    assert snap.health.band == :watch
  end

  test "FIRST-CLIENT WORST-OF-N (fix round 1, MED-2): CompanyLive never claims the book is current when a sibling subscription is past due" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id)

    seed_subscription(org_id, amount_cents: 10_000, status: :active)
    seed_subscription(org_id, amount_cents: 20_000, status: :past_due)

    html = render_live(CompanyLive, mount, [org_id, company.id])

    assert html =~ "worst status in book: past_due"
    refute html =~ "worst status in book: active"
  end

  # ==========================================================================
  # 9. Fix round 1, MED-3 — DEGRADED READ != a real zero
  # ==========================================================================

  test "snapshot/2 DEGRADED READ (fix round 1, MED-3): a genuinely FAILED read surfaces honest absence, never a fabricated $0/0" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    # A real subscription genuinely exists for this org — proving that, WITHOUT the
    # degraded-read fix, this scenario would render a plausible-looking "$0.00, no
    # subscriptions" instead of visibly-broken absence (Billing.Reads.metrics/2's own
    # internal `rescue -> 0` swallows exactly this class of failure once it's reached).
    seed_subscription(org_id, amount_cents: 19_900, status: :active)

    # `scope: nil` is not "correctly filtered to empty" (OrgScope fails CLOSED to an
    # empty result set for a scope-less actor, still `{:ok, []}`) — it is a MALFORMED
    # call that Ash itself rejects (`Ash.Error.Forbidden`, verified empirically) BEFORE
    # any policy runs. Representative of ANY genuine read failure this call site could
    # not previously distinguish from "truly zero".
    snap = AccountHealth.snapshot(mount, nil)

    assert snap.billing_available? == false
    assert snap.mrr_cents == nil
    assert snap.active_subs == nil
    assert snap.subscription_status == nil
    assert snap.past_due == nil

    assert snap.support_available? == false
    assert snap.open_tickets == nil
    assert snap.breaching_sla == nil

    assert snap.health.score == nil
    assert snap.health.band == :unknown
  end

  test "ANTI-TAUTOLOGY: the degraded-read scenario is real — the SAME org with a REAL scope reports its REAL $199.00" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    seed_subscription(org_id, amount_cents: 19_900, status: :active)

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    # Proves the degraded-read test above is a real property of the malformed scope,
    # not a bug that reports "unavailable" for every call regardless of input.
    assert snap.billing_available? == true
    assert snap.mrr_cents == 19_900
  end
end
