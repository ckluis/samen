defmodule Samen.Web.DunningMaskingTest do
  @moduledoc """
  F7 / G8 — THE PER-PLANE MASKING GATE for the billing-cockpit DUNNING surface
  (`Samen.Web.Billing.DunningLive`, reading `Samen.Web.Billing.Dunning.rows/3`). The
  dunning table renders the vault-routed (🔒) Billing `Customer.billing_name` /
  `billing_email`, so it joins the masking watch-list: the SAME account behind on payment
  renders CLEAR on the tenant plane and •••• on the operator plane.

  Consumer of `Samen.MaskingCase` — the green / red / sabotage-twin discipline shared with
  the file-preview, notifications, CSV-export, search-projection, and profile masking tests.

    * **GREEN** — the tenant plane resolves the dunning customer's `billing_name` CLEAR;
    * **RED** — an operator-without-grant renders the SAME dunning row as •••• with the
      plaintext ABSENT from the DOM and no `vt_*` vault token;
    * **SABOTAGE twin (anti-tautology)** — the mask scan is REFUTABLE: the SAME record read
      on the tenant plane DOES carry the plaintext the operator render masks
      (`assert_leak_detected!`), so the operator `refute` scans are non-vacuous.

  There is NO new committed sabotage patch: this surface introduces no new refutable code
  seam — the `__customer__` it renders is whatever `Reads.invoices/2` ALREADY resolved
  through `Samen.Api.PiiResolution` on the actor's plane, the SAME seam the shipped
  E4 search-projection plane-bypass sabotage (`10-e4-...`) already guards. The in-test
  `assert_leak_detected!` twin proves refutability without a redundant patch.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Web.Billing.Dunning
  alias Samen.Web.Billing.DunningLive

  # A distinctly-large, distinctly-old past-due invoice so the dunning row is unambiguous.
  @overdue_cents 50_000
  @overdue_days 40

  setup do
    seeded = Seeds.seed_all()
    customer = seeded.billing.customer

    # The seed's open invoice is FUTURE-due (not dunning). Add one PAST-DUE invoice for the
    # same customer so the account is provably in dunning.
    _past_due =
      Samen.WebTest.Billing.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: seeded.org_id,
          customer_id: customer.id,
          subscription_id: seeded.billing.subscription.id,
          status: :open,
          amount_due_cents: @overdue_cents,
          currency: "USD",
          due_date: DateTime.add(DateTime.utc_now(), -@overdue_days * 86_400, :second)
        },
        actor: %{org_id: seeded.org_id, role: :member},
        authorize?: false
      )
      |> Ash.create!()

    %{org_id: seeded.org_id, customer_id: customer.id}
  end

  defp render_dunning(org_id, plane_opts) do
    render_live(DunningLive, build_mount(:billing, plane_opts), [org_id])
  end

  # ==========================================================================
  # The compute surface is NON-VACUOUS (the account really is in dunning)
  # ==========================================================================

  test "Dunning.rows surfaces the past-due account with count/amount/days + status", %{
    org_id: org_id,
    customer_id: customer_id
  } do
    mount = build_mount(:billing)
    scope = Samen.Web.Mount.scope(mount, org_id)

    [row] = Dunning.rows(mount, scope)

    assert row.customer_id == customer_id
    assert row.past_due_count == 1
    assert row.amount_cents == @overdue_cents
    assert row.max_days_overdue >= @overdue_days
    assert row.sub_status == :active

    metrics = Dunning.metrics(mount, scope)
    assert metrics.accounts == 1
    assert metrics.overdue_cents == @overdue_cents
    assert metrics.invoices == 1
  end

  # ==========================================================================
  # GREEN — tenant plane resolves the dunning customer CLEAR
  # ==========================================================================

  test "TENANT plane: the dunning row renders billing_name CLEAR (green)", %{
    org_id: org_id,
    customer_id: customer_id
  } do
    html = render_dunning(org_id, plane: :tenant)

    # The row exists (non-vacuous: the account is actually in dunning) …
    assert html =~ "dunning-#{customer_id}"
    # … with the vaulted billing name/email resolved CLEAR …
    assert html =~ Seeds.customer_name()
    assert html =~ Seeds.customer_email()
    # … and no vault token leaks even on the clear plane (the resolver, not the raw column).
    refute html =~ "vt_"
  end

  # ==========================================================================
  # RED — operator-without-grant renders •••• (mask-by-omission), no vt_
  # ==========================================================================

  test "OPERATOR plane: the SAME dunning row renders •••• — DOM leak scan = 0", %{
    org_id: org_id,
    customer_id: customer_id
  } do
    html = render_dunning(org_id, plane: :operator, target_org_id: org_id)

    # The mask sentinel is PRESENT (impersonation = %Masked{} rendered, not omitted) and the
    # SAME dunning row exists (same customer_id) — so this is not a mask-everything vacuity.
    assert html =~ "dunning-#{customer_id}"
    assert_masked_dom!(html, [Seeds.customer_name(), Seeds.customer_email()])
  end

  # ==========================================================================
  # BOTH directions on the SAME record (anti-tautology) + refutable mask scan
  # ==========================================================================

  test "BOTH planes on the SAME account — tenant clear ∧ operator masked", %{org_id: org_id} do
    tenant_html = render_dunning(org_id, plane: :tenant)
    operator_html = render_dunning(org_id, plane: :operator, target_org_id: org_id)

    assert tenant_html =~ Seeds.customer_name()
    refute operator_html =~ Seeds.customer_name()
    assert operator_html =~ mask()
  end

  test "SABOTAGE twin: the mask scan is REFUTABLE — a tenant-plane render DOES leak the plaintext",
       %{org_id: org_id} do
    # AS-DESIGNED: the operator plane masks the customer (the refute scans above).
    operator_html = render_dunning(org_id, plane: :operator, target_org_id: org_id)
    refute operator_html =~ Seeds.customer_name()

    # SABOTAGE MODEL: a resolver that failed to mask would render the SAME dunning row in
    # the CLEAR — precisely the tenant-plane render. The leak scan FLIPS on it, proving the
    # operator `refute` scans are refutable (a real leak WOULD be caught), not vacuous.
    leaked_html = render_dunning(org_id, plane: :tenant)
    assert_leak_detected!(leaked_html, Seeds.customer_name())
    assert_leak_detected!(leaked_html, Seeds.customer_email())
  end
end
