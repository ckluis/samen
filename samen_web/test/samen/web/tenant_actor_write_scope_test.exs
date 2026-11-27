defmodule Samen.Web.TenantActorWriteScopeTest do
  @moduledoc """
  authz-8 review, S1: `TenantActor.write_scope/3` on an ARMED tenant mount returns the acting scope or nothing: anything that is not a
  `%Samen.Scope{}` fails closed (it used to fall through to `TenantRole.admin_scope/3`, which on an armed host with no
  principal answers a `:member` scope). Only the disarmed dev posture keeps the posture's admin elevation; a tenant page on the operator plane is read-only.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.{Mount, Plane, TenantActor}
  alias Samen.WebTest.RoleHarness, as: H
  alias Samen.WebTest.SecurityHost

  @labels %{
    otp_app: :samen_web_security_test_host,
    title: "Security Probe",
    authn: {:app_env, :samen_web_security_test_host, :auth_required?},
    authorized_orgs: {Samen.WebTest.SecurityHost, :authorized_org_ids, []},
    identity_namespace: Samen.WebTest.Operator
  }

  setup do
    H.setup_accounts()
  end

  defp mount, do: Mount.new(:billing, Samen.WebTest.Billing, Samen.WebTest.Repo, labels: @labels)

  defp operator_mount(org_id),
    do: Mount.new(:billing, Samen.WebTest.Billing, Samen.WebTest.Repo, labels: @labels, plane: Plane.operator("op-1", org_id, "sess-1"))

  defp acting(org_id, role),
    do: %Samen.Scope{actor: %{id: "u-1", org_id: org_id, role: role, kind: :tenant, plane: :tenant, resolved: true}}

  describe "write_scope/3 (S1)" do
    test "armed tenant mount: the acting scope itself; nil or anything else is refused, never a member or admin scope", ctx do
      assert Samen.Web.CurrentOrg.tenant_gate_armed?(mount())
      scope = acting(ctx.org_id, :member)

      # positive control: a real scope passes through untouched
      assert TenantActor.write_scope(mount(), ctx.org_id, scope) == scope

      for bad <- [nil, :none, %{actor: %{role: :admin}}, %{role: :admin}] do
        assert_raise ArgumentError, ~r/armed/, fn -> TenantActor.write_scope(mount(), ctx.org_id, bad) end
      end
    end

    test "disarmed dev posture: the posture's own admin elevation, with or without a scope", ctx do
      SecurityHost.disarm!()
      refute Samen.Web.CurrentOrg.tenant_gate_armed?(mount())

      assert %Samen.Scope{actor: %{role: :admin}} = TenantActor.write_scope(mount(), ctx.org_id, nil)
      assert %Samen.Scope{actor: %{role: :admin}} = TenantActor.write_scope(mount(), ctx.org_id, acting(ctx.org_id, :member))
    end

    test "operator plane: a tenant page there is read-only, whatever scope it is handed", ctx do
      op = operator_mount(ctx.org_id)

      for acting <- [nil, acting(ctx.org_id, :member), acting(ctx.org_id, :admin)] do
        assert %Samen.Scope{actor: %{role: :viewer, read_only: true, plane: :operator}} = TenantActor.write_scope(op, ctx.org_id, acting)
      end

      # positive control: the same scopes on the armed tenant mount are the acting scope itself
      assert TenantActor.write_scope(mount(), ctx.org_id, acting(ctx.org_id, :admin)).actor.role == :admin
    end
  end

  describe "user_scope/4 (the scope of a user a surface already resolved)" do
    test "a tenant mount carries the resolved user and role; no user, or an operator mount, is the plane's own scope", ctx do
      scope = TenantActor.user_scope(mount(), ctx.org_id, "u-1", :viewer)
      assert %{id: "u-1", role: :viewer, org_id: org_id, plane: :tenant} = scope.actor
      assert org_id == ctx.org_id

      # no role: the plane's role stays; no user: the plane's own actor
      assert TenantActor.user_scope(mount(), ctx.org_id, "u-1").actor.id == "u-1"
      assert TenantActor.user_scope(mount(), ctx.org_id, nil, :admin) == TenantActor.system_scope(mount(), ctx.org_id)

      op = operator_mount(ctx.org_id)
      assert TenantActor.user_scope(op, ctx.org_id, "u-1", :admin) == TenantActor.system_scope(op, ctx.org_id)
    end
  end
end
