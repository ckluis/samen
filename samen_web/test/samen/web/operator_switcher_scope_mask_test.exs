defmodule Samen.Web.OperatorSwitcherScopeMaskTest do
  @moduledoc """
  RP-J-14 (ADR-044 §16.2/§16.4a, T159 switcher residual) — the account-level NAME-scope
  3-proof for the SHARED operator "Act as a tenant →" workspace switcher
  (`Samen.Web.CurrentOrg.switcher/1`, rendered on EVERY operator surface via the
  `operator_sidebar` footer).

  Before this retrofit the switcher enumerated ALL account NAMES + `tenant_org_id`s to ANY
  operator role — the SAME cross-tenant name+id leak class T159 closed on the `/operator/accounts`
  ROWS, but on a shared component AND arguably worse (each entry is an actionable `/session/org/`
  act-as deep link, not a passive name). This applies the SAME `scope_of/2` seam +
  mask-by-omission the accounts list uses (`Samen.Web.Operator.AccountsLive.name_masked?/3`),
  on the KEYLESS `org_id` path — but the switcher entry, being a pure identity + act-as
  affordance with NO aggregate to preserve, is masked by being DROPPED ENTIRELY (no name, no
  org_id in any href).

    * **GREEN** — an operator WITH the scope right (`:all`, or `{:accounts, …}` covering the
      account) sees the account NAME + a working `/session/org/<tenant_org_id>` act-as link.
    * **RED** (mask by omission) — an operator WITHOUT the scope right (`:none`, or an
      `{:accounts, …}` excluding it) sees the entry GONE: NO name, NO `tenant_org_id` handle
      ANYWHERE in the switcher DOM (`assert_scope_masked!/3`).
    * **SABOTAGE twin** — flip `scope_of/2` permissive and the RED assertion FAILS
      (`assert_leak_detected!/2`) — the mask is refutable, not vacuous.
    * **mixed-render** (the salesperson case) — ONE switcher, ONE viewer: the in-scope account
      named + linked, the out-of-scope account dropped, in a SINGLE render.
    * **no-lockout** — a product wiring NO `:fleet_resolution` seam keeps EVERY entry
      (today's behaviour).
    * **fail-closed** — an ERRORING resolver collapses to `:none` ⇒ every entry dropped
      (the switcher hides), never leaked.
    * **consistency-with-accounts-list** — an operator who sees an account MASKED on
      `/operator/accounts` ALSO does not see it by name in the switcher: the FULL AccountsLive
      page (which renders the switcher in its sidebar) carries the tenant name NOWHERE.

  `async: false` — wires `:fleet_resolution` into an ISOLATED per-test otp_app (threaded onto
  the mount's `:otp_app` label) and resets it in `on_exit`, so no other suite (including the
  real `:samen_web` operator surfaces) ever sees a configured seam — they stay inert (all
  entries present, the no-lockout property).
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.ScopeMaskCase

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Operator.AccountsLive
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  # An isolated otp_app key — NOT :samen_web — so wiring the scope seam here cannot leak
  # into any other operator suite (which must keep the pre-Amendment all-entry behaviour).
  @otp_app :samen_web_operator_switcher_scope_test_host

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
  # fixed scope — mirrors `operator_accounts_scope_mask_test.exs`'s `const/2`.
  def const(value, _principal_id), do: value

  # A resolver that RAISES — proves the fail-closed posture (`scope_of/2` rescues to `:none`).
  def boom(_principal_id), do: raise("resolver boom")

  # Render the shared operator switcher with the given `scope_of/2` value wired. When `scope`
  # is `nil` NO seam is configured (the inert / no-lockout baseline); `:boom` wires the raising
  # resolver (the fail-closed proof).
  defp render_switcher(seed, scope) do
    case scope do
      nil -> Application.delete_env(@otp_app, :fleet_resolution)
      :boom -> Application.put_env(@otp_app, :fleet_resolution, {__MODULE__, :boom, []})
      value -> Application.put_env(@otp_app, :fleet_resolution, {__MODULE__, :const, [value]})
    end

    mount = build_operator_mount(seed.operator_org_id, labels: %{otp_app: @otp_app})

    %{mount: mount, org_id: nil, return_to: "/broker", __changed__: %{}}
    |> CurrentOrg.switcher()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  describe "RP-J-14 — the switcher account-level name-scope 3-proof" do
    test "GREEN: an :all-scope operator sees every account NAME + a working act-as link", ctx do
      html = render_switcher(ctx.seed, :all)

      assert_scope_resolved!(html, [ctx.name1, ctx.name2])
      # Each entry is a real /session/org/<tenant_org_id> act-as deep link.
      assert html =~ "/session/org/#{ctx.acct1.tenant_org_id}"
      assert html =~ "/session/org/#{ctx.acct2.tenant_org_id}"
      # The switcher itself is present (not hidden).
      assert html =~ "workspace-switcher"
    end

    test "RED: a :none-scope operator sees NEITHER name NOR the tenant_org_id handle", ctx do
      html = render_switcher(ctx.seed, :none)

      assert_scope_masked!(
        html,
        [ctx.name1, ctx.name2],
        [ctx.acct1.tenant_org_id, ctx.acct2.tenant_org_id]
      )
    end

    test "RED: a scoped-out {:accounts, other_org} operator sees both entries dropped", ctx do
      html = render_switcher(ctx.seed, {:accounts, MapSet.new(["some-other-org-entirely"])})

      assert_scope_masked!(
        html,
        [ctx.name1, ctx.name2],
        [ctx.acct1.tenant_org_id, ctx.acct2.tenant_org_id]
      )
    end

    test "SABOTAGE TWIN: flipping scope_of/2 permissive leaks the name+handle — the RED assertion FAILS",
         ctx do
      # The genuine RED proof first (the mask holds under the real :none seam).
      masked = render_switcher(ctx.seed, :none)
      assert_scope_masked!(masked, [ctx.name1], [ctx.acct1.tenant_org_id])

      # The sabotage: scope_of/2 permissive (:all) for the SAME operator — the mask is
      # refutable; the entry (name + act-as link) actually shows up, so the assertion above
      # is not vacuous.
      permissive = render_switcher(ctx.seed, :all)
      assert_leak_detected!(permissive, ctx.name1)
      assert permissive =~ "/session/org/#{ctx.acct1.tenant_org_id}"

      # And the RED assertion genuinely FAILS against the permissive render.
      assert_raise ExUnit.AssertionError, fn ->
        assert_scope_masked!(permissive, [ctx.name1], [ctx.acct1.tenant_org_id])
      end
    end
  end

  describe "mixed-render — one switcher, one viewer, named + dropped entries (§16.3 salesperson case)" do
    test "an operator scoped to ONE account sees it named+linked and the OTHER dropped, in ONE render",
         ctx do
      html = render_switcher(ctx.seed, {:accounts, MapSet.new([ctx.acct1.tenant_org_id])})

      assert_scope_resolved!(html, [ctx.name1])
      assert html =~ "/session/org/#{ctx.acct1.tenant_org_id}"
      assert_scope_masked!(html, [ctx.name2], [ctx.acct2.tenant_org_id])
    end
  end

  describe "no-lockout — a product wiring NO :fleet_resolution seam keeps today's behaviour" do
    test "with no seam configured every account NAME + act-as link is present (inert)", ctx do
      html = render_switcher(ctx.seed, nil)

      assert_scope_resolved!(html, [ctx.name1, ctx.name2])
      assert html =~ "/session/org/#{ctx.acct1.tenant_org_id}"
      assert html =~ "/session/org/#{ctx.acct2.tenant_org_id}"
    end
  end

  describe "fail-closed — an erroring resolver masks (drops every entry), never exposes" do
    test "a raising :fleet_resolution resolver collapses to :none: NO name, NO handle survives",
         ctx do
      html = render_switcher(ctx.seed, :boom)

      assert_scope_masked!(
        html,
        [ctx.name1, ctx.name2],
        [ctx.acct1.tenant_org_id, ctx.acct2.tenant_org_id]
      )

      # Every entry dropped ⇒ the empty switcher hides entirely (§ `:if={@orgs != []}`).
      refute html =~ "workspace-switcher"
    end
  end

  describe "consistency-with-accounts-list — the two surfaces AGREE for the same seat" do
    test "an account MASKED on /operator/accounts is ALSO absent by name from the sidebar switcher",
         ctx do
      # Wire the SAME :none scope the accounts list masks under, then render the WHOLE
      # AccountsLive page — which renders the switcher in its own sidebar footer. The tenant
      # NAME + tenant_org_id must appear NOWHERE on the full page: the rows mask (T159) AND
      # the switcher masks (this residual), so the two surfaces agree.
      Application.put_env(@otp_app, :fleet_resolution, {__MODULE__, :const, [:none]})

      mount = build_operator_mount(ctx.seed.operator_org_id, labels: %{otp_app: @otp_app})
      full_page = render_live(AccountsLive, mount, [])

      assert_scope_masked!(
        full_page,
        [ctx.name1, ctx.name2],
        [ctx.acct1.tenant_org_id, ctx.acct2.tenant_org_id]
      )

      # The accounts ROWS still render opaquely (T159 mask-by-omission) — the page is not blank.
      assert full_page =~ "not in your scope"
    end
  end
end
