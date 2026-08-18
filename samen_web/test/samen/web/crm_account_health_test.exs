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
    billing_email = Keyword.get(opts, :billing_email, "billing-#{System.unique_integer([:positive])}@example.com")

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
          billing_email: billing_email,
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

  defp seed_company(org_id, name \\ "Acme Freight Co", attrs \\ %{}) do
    Samen.WebTest.Crm.Company
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org_id, name: name}, attrs), authorize?: false)
    |> Ash.create!()
  end

  # T160 helpers ------------------------------------------------------------

  # Register + set the `billing_customer_id` anchor directly (bypassing the LiveView
  # event — used where a test wants the link ALREADY set before mount/render).
  defp anchor_company!(org_id, company, customer_id) do
    company_resource = Samen.WebTest.Crm.Company
    :ok = Samen.CRM.AccountLink.ensure_registered!(org_id, company_resource, Samen.WebTest.Repo)

    company
    |> Ash.Changeset.for_update(:update, %{custom: %{"billing_customer_id" => customer_id}, org_id: org_id}, authorize?: false)
    |> Ash.update!()
  end

  # Slice the rendered HTML into its two clearly-separated panels (see
  # `Samen.Web.CRM.CompanyLive`'s render) so a test can prove a number appears in ONE
  # panel and NOT the other — the precise form of the anti-regression guarantee this
  # whole task exists to prove (never render a book-wide number under a specific
  # company's own tiles).
  defp per_company_panel(html) do
    [_, rest] = String.split(html, ~s(id="account-health-panel"), parts: 2)
    [panel, _] = String.split(rest, ~s(id="portfolio-health-panel"), parts: 2)
    panel
  end

  defp portfolio_panel(html) do
    [_, rest] = String.split(html, ~s(id="portfolio-health-panel"), parts: 2)
    rest
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

  test "FIRST-CLIENT PORTFOLIO: CompanyLive's secondary portfolio panel renders MRR / health / open-support-ticket tiles from seeded data" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id)

    seed_subscription(org_id, amount_cents: 19_900, status: :active)
    seed_ticket(org_id, status: :open, breached: true)
    seed_ticket(org_id, status: :open, breached: false)

    html = render_live(CompanyLive, mount, [org_id, company.id])
    portfolio = portfolio_panel(html)

    assert portfolio =~ "portfolio-mrr"
    assert portfolio =~ "$199.00"
    assert portfolio =~ "portfolio-health-score"
    assert portfolio =~ "84 / 100"
    assert portfolio =~ "watch"
    assert portfolio =~ "portfolio-support-load"
    assert portfolio =~ "1 breaching SLA"

    # T160 — this company was NEVER linked (no anchor, no domain match set up), so the
    # PRIMARY per-company panel must NOT show the book's numbers under this company's
    # own name (the exact defect T160 closes) — honest "not linked", not a guess.
    per_company = per_company_panel(html)
    refute per_company =~ "$199.00"
    refute per_company =~ "84 / 100"
    assert per_company =~ "not linked to a billing account yet"
  end

  test "FIRST-CLIENT HONEST EMPTY: a fresh org renders real zeros in the portfolio panel — never a fabricated MRR/health/ticket number" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Fresh Co")

    html = render_live(CompanyLive, mount, [org_id, company.id])
    portfolio = portfolio_panel(html)

    # Rendered via an interpolated `{@sub}` expression (unlike the static disclosure
    # text below), so Phoenix.HTML escapes the apostrophe to `&#39;`.
    assert portfolio =~ "no subscriptions on file across this org&#39;s customers"
    assert portfolio =~ "40 / 100"
    assert portfolio =~ "at risk"
    assert portfolio =~ "none breaching SLA"

    per_company = per_company_panel(html)
    assert per_company =~ "not linked to a billing account yet"
  end

  # ==========================================================================
  # 7. Fix round 1, HIGH (portfolio) + T160 (per-company) — COPY HONESTY
  # ==========================================================================

  test "COPY HONESTY (fix round 1, HIGH): the SECONDARY portfolio panel's tiles/disclosure read as portfolio-wide totals, never this company's own numbers" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id)

    seed_subscription(org_id, amount_cents: 19_900, status: :active)

    html = render_live(CompanyLive, mount, [org_id, company.id])
    portfolio = portfolio_panel(html)

    # The corrected, honest labels/disclosure — now correctly scoped to the SECONDARY
    # portfolio panel (T160 made the per-company panel the primary/default view).
    assert portfolio =~ "Total MRR — all customers"
    assert portfolio =~ "Portfolio health"
    assert portfolio =~ "Open support tickets — all customers"
    assert portfolio =~ "org-wide totals across this org's ENTIRE customer &amp; support book"
    assert portfolio =~ "NOT this specific company's numbers"
    # T160 — the OLD claim ("the substrate does not have yet") is now FALSE (T160 built
    # the link) and must never reappear; the disclosure instead points at the linking
    # affordance the per-company panel now offers.
    refute portfolio =~ "the substrate does not have yet"
    assert portfolio =~ "link this company to a billing account above"

    # The REFUTED false claims (fix round 1) must never reappear: this is NOT "the
    # org's own relationship with the platform" copy.
    refute html =~ "own billing &amp; support relationship with the platform"
    refute html =~ "relationship with the platform"
  end

  test "T160 COPY HONESTY: the PRIMARY per-company panel never claims a book-wide number is this company's own, unlinked or linked" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id)

    # A large, distinctive book-wide MRR that would be UNMISTAKABLE if it leaked onto
    # the per-company panel.
    seed_subscription(org_id, amount_cents: 500_000, status: :active)

    html = render_live(CompanyLive, mount, [org_id, company.id])
    per_company = per_company_panel(html)

    refute per_company =~ "all customers"
    refute per_company =~ "$5000.00"
    assert per_company =~ "not linked to a billing account yet"
    # Interpolated (unlike the OLD static disclosure text), so Phoenix.HTML escapes
    # the apostrophe to `&#39;`.
    assert per_company =~ "never a guess, never a book-wide total under this company&#39;s name"
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
    portfolio = portfolio_panel(html)

    assert portfolio =~ "worst status in book: past_due"
    refute portfolio =~ "worst status in book: active"

    # T160 — this company is unlinked, so its OWN (primary) panel must not echo the
    # book's worst status as if it were this company's status.
    per_company = per_company_panel(html)
    refute per_company =~ "past_due"
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

  # ==========================================================================
  # 10. T160 — the linkage seam (Samen.CRM.AccountLink): anchor, domain fallback,
  #     honest unlinked absence, fail-closed no-cross-org, ambiguous -> no-match,
  #     anchor-authoritative-over-fallback
  # ==========================================================================

  test "T160 ANCHOR: a registered billing_customer_id anchor resolves THAT customer's real numbers" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id)
    %{customer: customer} = seed_subscription(org_id, amount_cents: 19_900, status: :active)

    anchored_company = anchor_company!(org_id, company, customer.id)

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot_for_company(mount, scope, anchored_company)

    assert snap.link_status == :anchor
    assert snap.billing_customer_id == customer.id
    assert snap.billing_available? == true
    assert snap.mrr_cents == 19_900
    assert snap.subscription_status == :active
    assert snap.support_available? == false
    assert snap.open_tickets == nil
  end

  test "T160 DOMAIN FALLBACK: no anchor set, but a SINGLE confident domain match resolves that customer" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Acme", %{domain: "acme-t160.example"})
    %{customer: customer} = seed_subscription(org_id, amount_cents: 29_900, status: :active, billing_email: "ap@acme-t160.example")

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot_for_company(mount, scope, company)

    assert snap.link_status == :domain
    assert snap.billing_customer_id == customer.id
    assert snap.mrr_cents == 29_900
  end

  test "T160 UNLINKED: no anchor, no domain match -> honest absence, NEVER a book-wide number, NEVER a fabricated $0" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "No Link Co", %{domain: "nolink-t160.example"})
    # A real subscription exists in the book, but under a DIFFERENT domain — no match.
    seed_subscription(org_id, amount_cents: 19_900, status: :active, billing_email: "ap@other-domain.example")

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot_for_company(mount, scope, company)

    assert snap.link_status == :unlinked
    assert snap.billing_customer_id == nil
    assert snap.billing_available? == false
    assert snap.mrr_cents == nil
    refute snap.mrr_cents == 0
    assert snap.health == nil
  end

  test "T160 DEGRADED READ (per-company): customer_billing_snapshot/3's own canary surfaces honest absence, never a fabricated $0" do
    billing_mount = build_mount(:billing)
    org_id = Ash.UUID.generate()
    %{customer: customer} = seed_subscription(org_id, amount_cents: 19_900, status: :active)

    # `scope: nil` is a malformed call Ash itself rejects (Ash.Error.Forbidden) BEFORE any
    # policy runs — the SAME representative genuine-failure shape `snapshot/2`'s own
    # degraded-read test uses, applied directly to the per-company read function T160 adds.
    result = AccountHealth.customer_billing_snapshot(billing_mount, nil, customer.id)

    assert result == nil
    refute result == %{mrr_cents: 0, active_subs: 0, subscription_status: nil, past_due: %{count: 0, amount_cents: 0, max_days_overdue: 0}}
  end

  test "ANTI-TAUTOLOGY: the per-company degraded-read scenario is real — the SAME customer with a REAL scope reports its REAL $199.00" do
    billing_mount = build_mount(:billing)
    org_id = Ash.UUID.generate()
    %{customer: customer} = seed_subscription(org_id, amount_cents: 19_900, status: :active)

    scope = Samen.Web.Mount.scope(billing_mount, org_id)
    result = AccountHealth.customer_billing_snapshot(billing_mount, scope, customer.id)

    refute result == nil
    assert result.mrr_cents == 19_900
  end

  test "T160 FAIL-CLOSED AMBIGUOUS: TWO customers share the same domain -> honest no-match, never a guess" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Ambiguous Co", %{domain: "ambiguous-t160.example"})
    seed_subscription(org_id, amount_cents: 10_000, status: :active, billing_email: "ap@ambiguous-t160.example")
    seed_subscription(org_id, amount_cents: 20_000, status: :active, billing_email: "billing@ambiguous-t160.example")

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot_for_company(mount, scope, company)

    assert snap.link_status == :unlinked
    refute snap.mrr_cents == 10_000
    refute snap.mrr_cents == 20_000
  end

  test "T160 FAIL-CLOSED NO-CROSS-ORG (the T74 lesson): a company's domain matches a DIFFERENT org's billing customer -> NEVER links across orgs" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    company_a = seed_company(org_a, "Org A Co", %{domain: "shared-domain-t160.example"})
    # Org B genuinely holds a customer whose domain happens to match — the refutation
    # setup (a seed that never landed anywhere would trivially pass).
    seed_subscription(org_b, amount_cents: 77_700, status: :active, billing_email: "ap@shared-domain-t160.example")

    scope_a = Samen.Web.Mount.scope(mount, org_a)
    snap_a = AccountHealth.snapshot_for_company(mount, scope_a, company_a)

    assert snap_a.link_status == :unlinked
    refute snap_a.mrr_cents == 77_700

    # Refutation control: org B's OWN company, same domain, resolves normally within B.
    company_b = seed_company(org_b, "Org B Co", %{domain: "shared-domain-t160.example"})
    scope_b = Samen.Web.Mount.scope(mount, org_b)
    snap_b = AccountHealth.snapshot_for_company(mount, scope_b, company_b)

    assert snap_b.link_status == :domain
    assert snap_b.mrr_cents == 77_700
  end

  test "T160 ANCHOR-AUTHORITATIVE-OVER-FALLBACK: a set anchor is NEVER overridden by a domain match, even a would-be-different one" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Authoritative Co", %{domain: "authoritative-t160.example"})

    %{customer: anchored_customer} = seed_subscription(org_id, amount_cents: 11_100, status: :active)
    # A SECOND customer whose domain WOULD confidently match this company's domain —
    # if the fallback were consulted, it would resolve to THIS one instead.
    %{customer: domain_customer} =
      seed_subscription(org_id, amount_cents: 99_900, status: :active, billing_email: "ap@authoritative-t160.example")

    anchored_company = anchor_company!(org_id, company, anchored_customer.id)

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot_for_company(mount, scope, anchored_company)

    assert snap.link_status == :anchor
    assert snap.billing_customer_id == anchored_customer.id
    assert snap.mrr_cents == 11_100
    refute snap.billing_customer_id == domain_customer.id
    refute snap.mrr_cents == 99_900
  end

  test "T160 ANCHOR-AUTHORITATIVE, but BROKEN (wrong org / deleted) -> honest absence, NEVER a silent re-guess via domain" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    other_org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Broken Anchor Co", %{domain: "broken-anchor-t160.example"})

    # This company's domain WOULD confidently match its own org's customer below — but
    # the anchor points at a customer in a DIFFERENT org (simulating stale/corrupt data).
    %{customer: same_org_domain_customer} =
      seed_subscription(org_id, amount_cents: 44_400, status: :active, billing_email: "ap@broken-anchor-t160.example")

    %{customer: other_org_customer} = seed_subscription(other_org_id, amount_cents: 12_300, status: :active)

    scope = Samen.Web.Mount.scope(mount, org_id)
    company_with_broken_anchor = %{company | custom: %{"billing_customer_id" => other_org_customer.id}}
    snap = AccountHealth.snapshot_for_company(mount, scope, company_with_broken_anchor)

    assert snap.link_status == :unlinked
    refute snap.mrr_cents == 12_300
    refute snap.mrr_cents == 44_400
    refute snap.billing_customer_id == same_org_domain_customer.id
  end

  test "T160 ZERO-MIGRATION: the anchor is a registered Tier-1 custom field, writable through the ordinary Ash :update action" do
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Registered Anchor Co")

    :ok = Samen.CRM.AccountLink.ensure_registered!(org_id, Samen.WebTest.Crm.Company, Samen.WebTest.Repo)

    assert %Samen.CustomFields.FieldRow{} =
             field = Samen.CustomFields.get_field(org_id, "swc_company", "billing_customer_id", Samen.WebTest.Repo)

    assert field.tnt_type == "string"

    {:ok, updated} =
      company
      |> Ash.Changeset.for_update(:update, %{custom: %{"billing_customer_id" => Ash.UUID.generate()}, org_id: org_id},
        authorize?: false
      )
      |> Ash.update()

    assert is_binary(updated.custom["billing_customer_id"])

    # RED — an UNregistered custom-bag key on the SAME resource is still rejected (the
    # Tier-1 guard is not bypassed for this field; only the REGISTERED key is writable).
    fresh_org = Ash.UUID.generate()
    fresh_company = seed_company(fresh_org, "Unregistered Co")

    assert {:error, _} =
             fresh_company
             |> Ash.Changeset.for_update(
               :update,
               %{custom: %{"billing_customer_id" => Ash.UUID.generate()}, org_id: fresh_org},
               authorize?: false
             )
             |> Ash.update()
  end

  # ==========================================================================
  # 11. T160 — snapshot_for_company/3 masking (verified non-PII outward, verified the
  #     ONE PII field touched — Customer.billing_email — is resolver-only, never leaked)
  # ==========================================================================

  test "T160 MASKING: snapshot_for_company/3 never returns a vault field, and Company.domain (the match key) is NOT vault-routed" do
    refute Samen.Pii.Info.vault_routed?(Samen.WebTest.Crm.Company, :domain)
    assert Samen.Pii.Info.vault_routed?(Samen.WebTest.Billing.Customer, :billing_email)

    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Mask Co", %{domain: "mask-t160.example"})
    seed_subscription(org_id, amount_cents: 19_900, status: :active, billing_email: "ap@mask-t160.example")

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot_for_company(mount, scope, company)

    assert snap.link_status == :domain

    # Every value in the returned snapshot is a bounded scalar (id/atom/integer/map of
    # counts) — never a %Masked{} struct, never a raw billing_email, never a vt_* token.
    refute match?(%Samen.Masked{}, snap.billing_customer_id)
    refute inspect(snap) =~ "vt_"
    refute inspect(snap) =~ "@mask-t160.example"
  end

  test "T160 MASKING: AccountLink never calls Samen.Vault.reveal directly (source-grep anti-tautology)" do
    src = File.read!("../samen_core/lib/samen/crm/account_link.ex")
    refute src =~ "Vault.reveal"
  end

  # ==========================================================================
  # 12. T160 P3/P4/P5/P6 — folded-in T77-deferred punch items (portfolio path)
  # ==========================================================================

  test "T160 P3: PORTFOLIO FLOOR fixed — one historical cancelled subscription among many healthy ones no longer pins billing to 0.0" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    for _ <- 1..9, do: seed_subscription(org_id, amount_cents: 9_900, status: :active)
    seed_subscription(org_id, amount_cents: 9_900, status: :cancelled)

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    billing = Enum.find(snap.health.factors, &(&1.name == :billing))
    # 9 live (active), 0 dunning -> value 1.0 (the OLD worst-of-N formula would have
    # pinned this at 0.0 purely from the ONE cancelled subscription — D4b).
    assert_in_delta billing.value, 1.0, 1.0e-9
    refute billing.value == 0.0
    # The TRUE worst status (display text) still honestly shows cancelled — churn is
    # surfaced, never hidden, just no longer allowed to floor the score alone.
    assert snap.subscription_status in [:cancelled, :canceled]
    assert billing.explanation =~ "1 cancelled subscription(s) excluded from the floor"
  end

  test "T160 P3: a book with ZERO live subscriptions (every one cancelled) still floors to 0.0 — genuine churn, not a false floor" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    seed_subscription(org_id, amount_cents: 9_900, status: :cancelled)
    seed_subscription(org_id, amount_cents: 9_900, status: :cancelled)

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    billing = Enum.find(snap.health.factors, &(&1.name == :billing))
    assert billing.value == 0.0
    assert billing.explanation =~ "every subscription on file (2) is cancelled"
  end

  test "T160 P4: portfolio worst-status/past-due are TRUE DB aggregates, not a 200-row-bounded approximation" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()

    # 205 healthy active subscriptions, THEN one genuinely past_due — past the OLD
    # 200-row bound (Billing.Reads.subscriptions/2's `@detail_limit`).
    for _ <- 1..205, do: seed_subscription(org_id, amount_cents: 100, status: :active)
    seed_subscription(org_id, amount_cents: 100, status: :past_due)

    scope = Samen.Web.Mount.scope(mount, org_id)
    snap = AccountHealth.snapshot(mount, scope)

    # The TRUE worst status is found regardless of book size — a 200-row-bounded read
    # sorted oldest-first would have missed this (the past_due row is the 206th).
    assert snap.subscription_status == :past_due

    billing = Enum.find(snap.health.factors, &(&1.name == :billing))
    refute billing.explanation =~ "no past-due invoices anywhere in the book"
  end

  test "T160 P5: :inactive is a recognized, neutral status — never rendered as 'unrecognized'" do
    breakdown =
      AccountHealth.score(%{
        billing: %{subscription_status: :inactive, past_due: %{count: 0, amount_cents: 0, max_days_overdue: 0}},
        support: nil
      })

    billing = Enum.find(breakdown.factors, &(&1.name == :billing))
    assert_in_delta billing.value, 0.5, 1.0e-9
    assert billing.explanation =~ "inactive"
    refute billing.explanation =~ "unrecognized"
  end

  test "T160 P6: dunning copy never claims '0 past-due invoice(s) ... $0.00 overdue' when dunning is purely status-driven" do
    breakdown =
      AccountHealth.score(%{
        billing: %{subscription_status: :past_due, past_due: %{count: 0, amount_cents: 0, max_days_overdue: 0}},
        support: nil
      })

    billing = Enum.find(breakdown.factors, &(&1.name == :billing))
    refute billing.explanation =~ "0 past-due invoice(s)"
    refute billing.explanation =~ "$0.00 overdue"
    assert billing.explanation =~ "past_due"
  end

  # ==========================================================================
  # 13. T160 — the write affordance (CompanyLive's link_billing_customer event)
  # ==========================================================================

  test "T160 WRITE: linking via the CompanyLive event round-trips — the per-company panel then shows THAT customer's real numbers" do
    mount = build_mount(:crm)
    org_id = Ash.UUID.generate()
    company = seed_company(org_id, "Live Link Co")
    %{customer: customer} = seed_subscription(org_id, amount_cents: 15_500, status: :active)

    session = mount_session(mount)
    {:ok, socket} = CompanyLive.mount(%{"id" => company.id}, session, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = CompanyLive.handle_params(%{"org" => org_id, "id" => company.id}, "http://localhost/x", socket)

    {:noreply, socket} =
      CompanyLive.handle_event("link_billing_customer", %{"billing_customer_id" => customer.id}, socket)

    assert socket.assigns.link_error == nil
    assert socket.assigns.account_health.link_status == :anchor
    assert socket.assigns.account_health.billing_customer_id == customer.id
    assert socket.assigns.account_health.mrr_cents == 15_500

    # Clearing (blank id) removes the anchor — falls back to unlinked (no domain set).
    {:noreply, socket} = CompanyLive.handle_event("link_billing_customer", %{"billing_customer_id" => ""}, socket)
    assert socket.assigns.account_health.link_status == :unlinked
  end
end
