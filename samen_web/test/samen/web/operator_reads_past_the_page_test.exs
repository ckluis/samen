defmodule Samen.Web.OperatorReadsPastThePageTest do
  @moduledoc """
  The operator joins (accounts, platform billing, desk) read every row in keyset pages: a book with
  more tenants than one page is counted, summed and listed in full, not cut at its first page.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  @tenants 203

  setup do
    seed = OpSeeds.seed_all(tenants: @tenants)
    mount = build_operator_mount(seed.operator_org_id)
    %{seed: seed, mount: mount, scope: Operator.scope(mount)}
  end

  test "the accounts header counts every account past the first page", ctx do
    assert {:ok, %{accounts: @tenants}} = Reads.account_metrics_result(ctx.mount, ctx.scope, ctx.seed.operator_org_id)
    assert length(Reads.account_names(ctx.mount, ctx.seed.operator_org_id)) == @tenants
  end

  test "platform billing lists and sums every subscription past the first page", ctx do
    billing = Reads.platform_billing(ctx.mount, ctx.scope)
    assert length(billing.subscriptions) == @tenants
    assert billing.active_subs == Enum.count(billing.subscriptions, &(&1.status == :active))

    # Positive control: the sum is exactly the sum of the rows (no row dropped from the total).
    assert billing.mrr_cents ==
             billing.subscriptions |> Enum.filter(&(&1.status == :active)) |> Enum.map(& &1.__mrr_cents__) |> Enum.sum()
  end

  test "the desk lists every ticket past the first page", ctx do
    expected = ctx.seed.accounts |> Enum.map(&length(&1.tickets)) |> Enum.sum()
    assert expected > 200
    assert length(Reads.desk(ctx.mount, ctx.scope)) == expected
  end
end
