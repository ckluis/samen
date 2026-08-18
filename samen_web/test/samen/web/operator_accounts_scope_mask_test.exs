defmodule Samen.Web.OperatorAccountsScopeMaskTest do
  @moduledoc """
  RP-J-14 (ADR-044 §16.2/§16.4a, T159 — OPERATOR RULING 2026-08-06) — the account-level
  NAME-scope 3-proof for `Samen.Web.Operator.AccountsLive` (the `/operator/accounts` list),
  consuming T84a's `Samen.ScopeMaskCase` harness (the SECOND mask class — mask by omission,
  no `••••`, no plane).

  Before this retrofit every org NAME on `/operator/accounts` was visible to ANY operator
  role. This applies the SAME `scope_of/2` seam + mask-by-omission the fleet tier-2 detail
  (`Samen.Web.Operator.FleetDetailLive`, `fleet_detail_scope_mask_test.exs`) uses — but on
  the KEYLESS `org_id` path (the surface holds real `tenant_org_id`s, not opaque wire
  handles), exactly like the R-B impersonation drill-in gate.

    * **GREEN** — an operator WITH the scope right (`:all`, or an `{:accounts, …}` covering
      the account) sees the account NAME in plaintext (`assert_scope_resolved!/2`).
    * **RED** (mask by omission) — an operator WITHOUT the scope right (`:none`, or an
      `{:accounts, …}` excluding it) sees the account masked: NO name, NO tenant-admin
      contact, and NO `tenant_org_id` handle ANYWHERE in the DOM (`assert_scope_masked!/3`).
    * **SABOTAGE twin** — flip `scope_of/2` permissive and the RED assertion FAILS
      (`assert_leak_detected!/2`) — the mask is refutable, not vacuous.
    * **mixed-render** (the salesperson case) — ONE table, ONE viewer: the in-scope account
      named, the out-of-scope account masked, in a SINGLE render.
    * **aggregate-preserved** — a legitimate role-gated cross-tenant AGGREGATE (Platform MRR,
      the per-row MRR) still renders even when EVERY name is masked (scope subtracts NAMES,
      not aggregates).
    * **T146-still-gates** — the operator-ROLE gate still refuses a non-operator entirely;
      name-scoping is ADDITIVE, layered on top, never a substitute.

  `async: false` — wires `:fleet_resolution` into an ISOLATED per-test otp_app (threaded onto
  the mount's `:otp_app` label) and resets it in `on_exit`, so no other suite (including the
  real `:samen_web` operator surfaces) ever sees a configured seam — they stay inert (all
  names clear, the no-lockout property).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.ScopeMaskCase

  alias Samen.Web.Operator.AccountsLive
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  # An isolated otp_app key — NOT :samen_web — so wiring the scope seam here cannot leak
  # into any other operator suite (which must keep the pre-Amendment all-clear behaviour).
  @otp_app :samen_web_operator_accounts_scope_test_host

  setup do
    on_exit(fn -> Application.delete_env(@otp_app, :fleet_resolution) end)

    seed = OpSeeds.seed_all(tenants: 2)
    acct1 = Enum.at(seed.accounts, 0)
    acct2 = Enum.at(seed.accounts, 1)

    %{
      seed: seed,
      acct1: acct1,
      acct2: acct2,
      name1: "Blue Ridge Logistics 1",
      name2: "Blue Ridge Logistics 2"
    }
  end

  # A closed-shape `:fleet_resolution` resolver that ignores the principal and returns a
  # fixed scope — mirrors `fleet_detail_scope_mask_test.exs`'s `const/2`.
  def const(value, _principal_id), do: value

  # Render `/operator/accounts` with the given `scope_of/2` value wired. When `scope` is
  # `nil` NO seam is configured (the inert / no-lockout baseline).
  defp render_with_scope(seed, scope) do
    if scope == nil do
      Application.delete_env(@otp_app, :fleet_resolution)
    else
      Application.put_env(@otp_app, :fleet_resolution, {__MODULE__, :const, [scope]})
    end

    mount = build_operator_mount(seed.operator_org_id, labels: %{otp_app: @otp_app})
    render_live(AccountsLive, mount, [])
  end

  # The ACCOUNTS LIST region of the surface (everything from the list table onward) — the
  # thing T159 governs. The `scope_of/2` name-mask 3-proof is asserted HERE, not against the
  # whole page: the shared operator sidebar's "Act as a tenant →" workspace switcher
  # (`Samen.Web.CurrentOrg.switcher`, present IDENTICALLY on every operator surface —
  # billing/revenue/desk/flags — not the accounts list) enumerates cross-tenant names/ids as
  # pre-existing chrome. Scope-masking THAT shared component is a distinct cross-cutting
  # concern outside this ruling's "/operator/accounts" remit (and the "do not touch outside"
  # rule). This slice pins the guarantee to the account ROWS, exactly what T159 retrofits.
  defp list_region(html) do
    case String.split(html, ~s(id="accounts-list"), parts: 2) do
      [_, rest] -> rest
      _ -> html
    end
  end

  describe "RP-J-14 — the account-level name-scope 3-proof" do
    test "GREEN: an :all-scope operator sees every account NAME in plaintext", ctx do
      region = list_region(render_with_scope(ctx.seed, :all))

      assert_scope_resolved!(region, [ctx.name1, ctx.name2])
      # The tenant-admin contact (population 1) is clear for in-scope rows.
      assert region =~ OpSeeds.admin_full_name()
      refute region =~ "not in your scope"
    end

    test "RED: a :none-scope operator sees NEITHER name NOR the tenant_org_id handle", ctx do
      region = list_region(render_with_scope(ctx.seed, :none))

      assert_scope_masked!(
        region,
        [ctx.name1, ctx.name2],
        [ctx.acct1.tenant_org_id, ctx.acct2.tenant_org_id]
      )

      # The mask affordance proves the ROWS still exist (opaque), only the identity is gone.
      assert region =~ "not in your scope"
      # And no tenant-admin contact (population 1) leaks on a masked row either.
      refute region =~ OpSeeds.admin_full_name()
    end

    test "RED: a scoped-out {:accounts, other_org} operator sees both accounts masked", ctx do
      region = list_region(render_with_scope(ctx.seed, {:accounts, MapSet.new(["some-other-org-entirely"])}))

      assert_scope_masked!(
        region,
        [ctx.name1, ctx.name2],
        [ctx.acct1.tenant_org_id, ctx.acct2.tenant_org_id]
      )
    end

    test "SABOTAGE TWIN: flipping scope_of/2 permissive leaks the name+handle — the RED assertion FAILS",
         ctx do
      # The genuine RED proof first (the mask holds under the real :none seam).
      masked = list_region(render_with_scope(ctx.seed, :none))
      assert_scope_masked!(masked, [ctx.name1], [ctx.acct1.tenant_org_id])

      # The sabotage: scope_of/2 permissive (:all) for the SAME operator — the mask is
      # refutable; the leak actually shows up, so the assertion above is not vacuous.
      permissive = list_region(render_with_scope(ctx.seed, :all))
      assert_leak_detected!(permissive, ctx.name1)

      # And the RED assertion genuinely FAILS against the permissive render.
      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_masked!(permissive, [ctx.name1], [ctx.acct1.tenant_org_id])
      end
    end
  end

  describe "mixed-render — one table, one viewer, named + masked rows (§16.3 salesperson case)" do
    test "an operator scoped to ONE account sees it named and the OTHER masked, in the SAME render",
         ctx do
      region = list_region(render_with_scope(ctx.seed, {:accounts, MapSet.new([ctx.acct1.tenant_org_id])}))

      assert_scope_resolved!(region, [ctx.name1])
      assert_scope_masked!(region, [ctx.name2], [ctx.acct2.tenant_org_id])
    end
  end

  describe "no-lockout — a product wiring NO :fleet_resolution seam keeps today's behaviour" do
    test "with no seam configured every account NAME is clear (inert, the pre-Amendment default)",
         ctx do
      region = list_region(render_with_scope(ctx.seed, nil))

      assert_scope_resolved!(region, [ctx.name1, ctx.name2])
      refute region =~ "not in your scope"
    end
  end

  describe "aggregate-preserved — role-gated cross-tenant aggregates survive name-masking" do
    test "with EVERY name masked (:none) the Platform MRR + per-row MRR aggregates still render",
         ctx do
      html = render_with_scope(ctx.seed, :none)
      region = list_region(html)

      # Names are gone from the list rows (RED holds)…
      refute region =~ ctx.name1
      refute region =~ ctx.name2
      # …but the legitimate cross-tenant aggregate (role-gated, NOT per-account scoped) stays.
      assert html =~ "Platform MRR"
      # And the per-row MRR aggregate still renders on the masked (opaque) rows.
      assert region =~ "$499.00"
    end
  end

  describe "T146-still-gates — name-scoping is layered ON TOP of the operator-role gate" do
    test "the :require_operator on_mount still HALTS a principal with no operator authority" do
      # Name-scoping does not touch the T146 role gate: a non-operator (no :operator_authority
      # seam resolvable) is refused entirely, rendering nothing — regardless of any scope.
      socket = %Phoenix.LiveView.Socket{}
      assert {:halt, _} = Samen.Web.Operator.Authz.on_mount(:require_operator, %{}, %{}, socket)
    end
  end
end
