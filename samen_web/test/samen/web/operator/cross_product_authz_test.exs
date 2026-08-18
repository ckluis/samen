defmodule Samen.Web.Operator.CrossProductAuthzTest do
  @moduledoc """
  T83 / J3 — cross-product operator identity + per-product role scoping (ADR-044 §6.1–§6.3).

  ONE identity, N authorizations, each product the authority for its own plane. There is NO
  cross-product credential (§6.1); the fleet only standardizes how AUTHORIZATION is expressed
  per product, riding the SAME `:operator_authority` args-carrier the T146 primitive already
  applies (`Samen.Web.Operator.Authz.resolve_role/2` does `apply(mod, fun, args ++ [principal]))`).
  A fleet deployment bakes the product slug into that args list (`[:driftwood]` / `[:pawchart]`),
  so one operator login reaches products A and B according to per-product assigned roles.

  Two done-criteria pinned here (handoff):
    1. **cross-product login** — one credential reaches products A and B per its assigned roles.
    2. **role-isolation RED (RP-J-5)** — a role granted in product A confers ZERO capability in
       product B, asserted per-capability row-by-row, each with a same-product positive control
       (anti-tautology: the denial can fail).

  SABOTAGE-REFUTABLE: drop the args-carrier from `resolve_role/2` (resolve the role WITHOUT the
  per-product scope) and the isolation rows flip green→leak — proven by
  `scripts/sabotages/117-t83-j3-operator-role-cross-product-scope-drop.patch`.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.{Mount, Operator, Plane}
  alias Samen.Web.Operator.Authz

  # The host cross-product grant store, in the EXACT shape ADR-044 §6.2 names:
  # `%{principal_id => %{app_scope => role}}`, read by `get_in(grants(), [principal, scope])`.
  # This is the co-resident "one Fleet.Auth wired into both apps" posture (§6.5).
  defmodule Fixture do
    @grants %{
      # alice: an admin on product A ONLY.
      "alice" => %{app_a: :operator_admin},
      # bob: support on product B ONLY.
      "bob" => %{app_b: :operator_support},
      # carol: ONE login reaching BOTH products at DIFFERENT roles (cross-product login).
      "carol" => %{app_a: :operator_readonly, app_b: :operator_admin}
    }

    def operator_role(app_scope, principal_id), do: get_in(@grants, [principal_id, app_scope])
  end

  # A mount scoped to `app_scope` — the `[app_scope]` args list is the product-scope carrier.
  defp mount(app_scope) do
    Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
      plane: Plane.tenant(),
      labels: %{operator_authority: {Fixture, :operator_role, [app_scope]}}
    )
  end

  defp session(principal_id), do: %{Samen.Web.Auth.session_user_key() => principal_id}

  describe "done-criterion 1 — cross-product login: one credential, per-product roles" do
    test "carol's single identity reaches product A and product B at her ASSIGNED per-product roles" do
      assert Authz.resolve_role(mount(:app_a), session("carol")) == :operator_readonly
      assert Authz.resolve_role(mount(:app_b), session("carol")) == :operator_admin
    end

    test "one login spans products — the role differs per product, not per session" do
      # Same session principal, two mounts: the ROLE is resolved from the product scope, not
      # from any cross-product token. There is no fleet bearer credential in this flow at all.
      s = session("carol")
      assert Authz.resolve_role(mount(:app_a), s) != Authz.resolve_role(mount(:app_b), s)
    end
  end

  describe "done-criterion 2 — RP-J-5 role isolation: a role in A confers ZERO capability in B" do
    # Per-capability table: {viewer, home_product, home_role, foreign_product}.
    # RED asserts the foreign product resolves nil; the same-product CONTROL proves the row's
    # denial can fail (the credential genuinely holds a role — in its OWN product).
    # NOTE: carol is deliberately absent — she is the cross-product LOGIN case (roles in BOTH),
    # covered by done-criterion 1. Isolation is asserted for single-product operators.
    @isolation [
      {"alice", :app_a, :operator_admin, :app_b},
      {"bob", :app_b, :operator_support, :app_a}
    ]

    for {principal, home, home_role, foreign} <- @isolation do
      test "#{principal}: #{home_role} on #{home} confers NOTHING on #{foreign}" do
        principal = unquote(principal)
        home = unquote(home)
        home_role = unquote(home_role)
        foreign = unquote(foreign)

        # CONTROL (positive): the credential really does hold a role in its OWN product.
        assert Authz.resolve_role(mount(home), session(principal)) == home_role,
               "positive control failed — #{principal} should hold #{home_role} on #{home}"

        # RED: that SAME login resolves NO role on the foreign product — halt, renders nothing.
        assert Authz.resolve_role(mount(foreign), session(principal)) == nil,
               "ROLE ISOLATION BREACH — #{principal}'s #{home} role leaked into #{foreign}"
      end
    end

    test "the isolation extends to the on_mount hook: a foreign-product mount HALTS the login" do
      # End-to-end at the surface: alice (admin on app_a) is refused on app_b's operator plane.
      mount_session = %{"samen_mount" => Mount.to_session(mount(:app_b))}
      session = Map.merge(mount_session, session("alice"))
      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, _redirected} = Authz.on_mount(:require_operator, %{}, session, socket)

      # positive control — alice's OWN product (app_a) admits her with the role assigned.
      own_session =
        Map.merge(%{"samen_mount" => Mount.to_session(mount(:app_a))}, session("alice"))

      assert {:cont, cont_socket} = Authz.on_mount(:require_operator, %{}, own_session, socket)
      assert cont_socket.assigns.samen_operator_role == :operator_admin
    end
  end

  describe "fail-closed posture is preserved by the scoping" do
    test "an unknown {principal, product} pair resolves nil (deny-by-default)" do
      assert Authz.resolve_role(mount(:app_a), session("nobody")) == nil
      assert Authz.resolve_role(mount(:unwired_product), session("alice")) == nil
    end

    test "Operator.scope/1 is unchanged — the identity line still hinges on the operator org" do
      # J3 changes AUTHORIZATION only; the tenant-plane operator-org scope is untouched.
      mount = Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
        plane: Plane.tenant(),
        labels: %{operator_org_id: "op-1", operator_authority: {Fixture, :operator_role, [:app_a]}}
      )

      assert Operator.scope(mount).actor.org_id == "op-1"
    end
  end
end
