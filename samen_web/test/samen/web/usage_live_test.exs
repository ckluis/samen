defmodule Samen.Web.UsageLiveTest do
  @moduledoc """
  T163 (ADR-051 P4) — the tenant usage panel (`Samen.Web.Billing.UsageLive`, reading
  `Samen.Web.Billing.Reads.usage/2`).

    * The panel renders the DERIVED tallies: usage captured through
      `Samen.Billing.Meter.record/3` and tallied by `Samen.Billing.UsageTally.rebuild/5`,
      per metric and period, with how much has been sent to the provider.
    * **Quantities only — never a local price (D2).** The rendered page carries no
      currency amount, rate or spend estimate, and points at the provider's invoices
      instead. Sabotage 382 adds a local spend estimate and must flip that test.
    * Org-scoped: another org's usage never appears.
    * Read-only and non-PII: the operator plane renders the same quantities, and there
      is no write affordance on either plane.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Billing.{Meter, UsageTally}
  alias Samen.Web.Billing.{Reads, UsageLive}
  alias Samen.WebTest.Billing.{Usage, UsageEvent}

  @start ~U[2026-07-01 00:00:00Z]
  @stop ~U[2026-08-01 00:00:00Z]

  setup do
    seeded = Seeds.seed_all()
    %{org_id: seeded.org_id, sub_id: seeded.billing.subscription.id}
  end

  defp capture(org_id, sub_id, ref, attrs) do
    event =
      Map.merge(
        %{metric: :api_calls, quantity: 1, source_ref: ref, subscription_id: sub_id,
          occurred_at: ~U[2026-07-15 12:00:00Z]},
        attrs
      )

    assert {:ok, :recorded} = Meter.record(org_id, event, resource: UsageEvent)
  end

  defp rebuild(org_id, sub_id),
    do: UsageTally.rebuild(org_id, sub_id, @start, @stop, usage: Usage, usage_event: UsageEvent)

  defp render_usage(org_id, plane_opts \\ []),
    do: render_live(UsageLive, build_mount(:billing, plane_opts), [org_id])

  # The panel's own section, past the shared app shell (sidebar search form, nav), so the
  # assertions below are about what THIS page renders.
  defp panel(html) do
    [_shell, panel] = String.split(html, ~s(<div id="usage">), parts: 2)
    panel
  end

  defp seed_usage(%{org_id: o, sub_id: s}) do
    capture(o, s, "a", %{quantity: 1_200})
    capture(o, s, "b", %{quantity: 34})
    capture(o, s, "m", %{metric: :messages, quantity: 7})
    assert {:ok, %{api_calls: 1_234, messages: 7}} = rebuild(o, s)
  end

  test "Reads.usage returns the org's derived tallies", %{org_id: o} = ctx do
    seed_usage(ctx)
    mount = build_mount(:billing)

    rows = Reads.usage(mount, Samen.Web.Mount.scope(mount, o))
    assert rows |> Enum.map(&{&1.metric, &1.quantity, &1.reported_quantity}) |> Enum.sort() ==
             [{:api_calls, 1_234, 0}, {:messages, 7, 0}]
  end

  test "the panel renders each metric's quantity per period and what is not yet sent", %{org_id: o} = ctx do
    seed_usage(ctx)
    html = render_usage(o)

    assert html =~ "API calls"
    assert html =~ "1,234"
    assert html =~ "Messages"
    assert html =~ "Jul 1, 2026 – Aug 1, 2026"
    assert html =~ "1,234 not yet sent"
    assert html =~ "7 not yet sent"
  end

  test "quantities only: the panel shows no price, amount or spend estimate (D2)", %{org_id: o} = ctx do
    seed_usage(ctx)
    html = o |> render_usage() |> panel()

    # Positive control: the quantities ARE on the page, so the refutes below are not vacuous.
    assert html =~ "1,234"

    # No currency amount, rate or estimate anywhere in the panel. Money is mirrored from
    # the provider, never computed here; the page points at the provider's invoices.
    refute html =~ "$"
    refute html =~ ~r/USD|EUR|GBP/
    refute html =~ ~r/estimat|spend|cost|price|rate/i
    assert html =~ ~s(id="usage-invoices-link")
    assert html =~ "/billing/invoices?org=#{o}"
  end

  test "an org with no tallied usage sees the empty state", %{org_id: o} do
    html = render_usage(o)
    assert html =~ "No metered usage yet."
    refute html =~ "usage-row"
  end

  test "another org's usage never appears", %{org_id: o} = ctx do
    seed_usage(ctx)

    other = Seeds.seed_all()
    capture(other.org_id, other.billing.subscription.id, "other", %{quantity: 98_765})
    assert {:ok, _} = rebuild(other.org_id, other.billing.subscription.id)

    html = render_usage(o)
    assert html =~ "1,234"
    refute html =~ "98,765"
  end

  test "the operator plane renders the same quantities, read-only on both planes", %{org_id: o} = ctx do
    seed_usage(ctx)

    tenant = render_usage(o)
    operator = render_usage(o, plane: :operator, target_org_id: o)

    for html <- [panel(tenant), panel(operator)] do
      assert html =~ "1,234"
      refute html =~ "<form"
      refute html =~ "phx-click"
    end
  end
end
