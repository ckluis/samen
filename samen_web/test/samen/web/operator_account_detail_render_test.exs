defmodule Samen.Web.OperatorAccountDetailRenderTest do
  @moduledoc """
  Framework OPERATOR / Account drill-down render tests (WS-B / B4; ADR-019).

  AC-G17-4: `/operator/accounts/:id` renders the score + factor breakdown + the
  `mov` MRR-movement timeline + tickets + billing evidence, and `AccountsLive`
  links to it. AC-G17-2 at the SURFACE: the seeded account is ACTIVE with a
  past-due invoice — exactly the gate-flagged incoherence case — so the rendered
  billing dimension must NOT rate healthy while dunning; paying the invoice off
  flips it healthy (the positive control that keeps the must-fail refutable).
  AC-G17-5: on a hand-crafted `plane: :operator` mount the PII-bearing evidence
  (the ticket requester) renders `••••` — fail-MASKED, never fail-clear — while
  the score itself (not a PII surface) still renders; no `vt_` token ever leaks.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  setup do
    seed = OpSeeds.seed_all(tenants: 2)
    account = hd(seed.accounts)
    seed_movements!(seed.operator_org_id, account)
    %{seed: seed, account: account}
  end

  # Two mov ledger rows for the account's customer — the timeline's evidence.
  defp seed_movements!(operator_org_id, account) do
    movements = [
      {:new, 49_900, 0, 49_900, ~U[2026-05-10 12:00:00Z]},
      {:expansion, 5_000, 49_900, 54_900, ~U[2026-06-08 12:00:00Z]}
    ]

    for {kind, delta, before_c, after_c, at} <- movements do
      Op.SubscriptionEvent
      |> Ash.Changeset.for_create(
        :append,
        %{
          org_id: operator_org_id,
          subscription_id: account.subscription.id,
          customer_id: account.customer.id,
          kind: kind,
          mrr_delta_cents: delta,
          mrr_before_cents: before_c,
          mrr_after_cents: after_c,
          occurred_at: at
        },
        authorize?: false
      )
      |> Ash.create!()
    end
  end

  defp detail_html(seed, account) do
    render_live(
      Samen.Web.Operator.AccountDetailLive,
      build_operator_mount(seed.operator_org_id),
      [account.account_org.id]
    )
  end

  defp factor_row(html, name) do
    case Regex.run(~r/<tr[^>]*id="factor-#{name}".*?<\/tr>/s, html) do
      [row] -> row
      _ -> flunk("no factor-#{name} row rendered")
    end
  end

  # -- AC-G17-4: the drill-down surface -------------------------------------------

  test "renders the score, the four-factor breakdown, the mov timeline, tickets, and billing evidence", %{
    seed: seed,
    account: account
  } do
    html = detail_html(seed, account)

    assert html =~ ~s(class="app")
    assert html =~ "Health score"
    assert html =~ "Why this score"

    # All four explainable dimensions render with weight + contribution + why.
    for name <- [:billing, :activity, :support, :adoption] do
      row = factor_row(html, name)
      assert row =~ "pts"
    end

    # The activity dimension is honestly :unknown until G12 emits (AC-G17-7).
    assert factor_row(html, :activity) =~ "no signal"

    # The mov timeline renders the ledger rows (B1 evidence).
    assert html =~ "MRR movement timeline"
    assert html =~ "tl-entry"
    assert html =~ "expansion +$50.00"
    assert html =~ "$499.00 → $549.00"

    # Ticket + invoice evidence (the support / billing factor inputs).
    assert html =~ "Cannot invite a second admin"
    assert html =~ "account-ticket-"
    assert html =~ "Billing events"
    assert html =~ "past due"

    # PII posture on the operator's OWN tenant plane: requester clear, no mask.
    assert html =~ OpSeeds.admin_full_name()
    refute html =~ "••••"
  end

  test "AccountsLive drills into the detail (the health pill is the link)", %{seed: seed, account: account} do
    html = render_live(Samen.Web.Operator.AccountsLive, build_operator_mount(seed.operator_org_id), [])

    assert html =~ "account-drill"
    assert html =~ "/operator/accounts/#{account.account_org.id}"
  end

  test "an unknown account id renders the not-found card, never a crash", %{seed: seed} do
    html =
      render_live(
        Samen.Web.Operator.AccountDetailLive,
        build_operator_mount(seed.operator_org_id),
        [Ash.UUID.generate()]
      )

    assert html =~ "account-missing"
    assert html =~ "Account not found"
  end

  # -- AC-G17-2 at the surface: the incoherence fix, rendered ----------------------

  test "MUST-FAIL: the ACTIVE-but-past-due account renders a dunning billing dimension, never a healthy one; paying it off flips it (positive control)",
       %{seed: seed, account: account} do
    # The seeded account 1 is ACTIVE with one past-due invoice — the exact case
    # the old status pill rendered "healthy" and the gate flagged.
    html = detail_html(seed, account)
    billing_row = factor_row(html, :billing)

    assert billing_row =~ "in dunning"
    assert billing_row =~ "1 past-due invoice(s)"
    refute billing_row =~ ~r/>\s*healthy\s*</

    # POSITIVE CONTROL (anti-tautology): clear the dunning — the SAME account and
    # the SAME render path now rate the billing dimension healthy.
    account.past_due_invoice
    |> Ash.Changeset.for_update(:update, %{status: :paid}, authorize?: false)
    |> Ash.update!()

    paid_html = detail_html(seed, account)
    paid_row = factor_row(paid_html, :billing)

    assert paid_row =~ ~r/>\s*healthy\s*</
    assert paid_row =~ "no past-due invoices"
    refute paid_row =~ "in dunning"
  end

  # -- AC-G17-5: masking — the odd operator-plane mount fails MASKED ---------------

  test "on a hand-crafted plane: :operator mount the PII evidence renders •••• and no vt_ token leaks; the score (not a PII surface) still renders",
       %{seed: seed, account: account} do
    masked_mount =
      Samen.Web.Mount.new(
        :operator,
        Samen.WebTest.Operator,
        Samen.WebTest.Repo,
        plane: Samen.Web.Plane.operator("op-1", seed.operator_org_id, "test-session"),
        labels: %{operator_org_id: seed.operator_org_id}
      )

    html = render_live(Samen.Web.Operator.AccountDetailLive, masked_mount, [account.account_org.id])

    # The PII-bearing evidence (ticket requester) is MASKED on this plane.
    assert html =~ "account-ticket-"
    assert html =~ "••••"
    refute html =~ OpSeeds.admin_full_name()
    refute html =~ OpSeeds.admin_email()

    # No vault token ever reaches the HTML, on any plane.
    refute html =~ "vt_"

    # Health is NOT a PII surface (ADR-019 §3): the breakdown still renders —
    # every factor input is a bounded count/enum/amount, nothing to mask.
    assert html =~ "Why this score"
    assert html =~ ~s(id="factor-billing")
  end
end
