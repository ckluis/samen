defmodule Samen.Web.TenantActorRoleGatesTest do
  @moduledoc """
  authz-8 review, S3: `admin?/1` is false on the operator plane, like `administrable?/2` (an operator never sends a tenant's
  campaign), so the send handler that checks it refuses there. `member?/1` is deliberately left a rank check: the operator's
  synthetic scope is `:member`, and the operator red paths drive a reply through to the kernel's `WriteGuard`. The disarmed
  dev posture keeps `admin?/1` open, as before.
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

  describe "admin?/1 and member?/1 (S3)" do
    defp socket(mount, scope), do: %{assigns: %{acting_scope: scope, samen_mount: mount}}

    test "armed tenant plane: admin? is the admin rank, member? the member rank", ctx do
      assert TenantActor.admin?(socket(mount(), acting(ctx.org_id, :admin)))
      refute TenantActor.admin?(socket(mount(), acting(ctx.org_id, :member)))
      assert TenantActor.member?(socket(mount(), acting(ctx.org_id, :member)))
      refute TenantActor.member?(socket(mount(), acting(ctx.org_id, :viewer)))
    end

    test "the operator plane is not an admin of a tenant page (it does not send a tenant's campaign); member? stays a rank check", ctx do
      op = operator_mount(ctx.org_id)
      operator_scope = Plane.scope(op.plane, ctx.org_id)

      refute TenantActor.admin?(socket(op, operator_scope))
      refute TenantActor.admin?(socket(op, acting(ctx.org_id, :owner)))
      # member? is a rank check only: the kernel's plane guards (WriteGuard) are what refuse an operator's write, and the
      # operator red paths need to reach them (support_ticket_reply_test.exs)
      assert TenantActor.member?(socket(op, operator_scope))
    end

    test "disarmed dev posture: admin? stays open, as before", ctx do
      SecurityHost.disarm!()
      assert TenantActor.admin?(socket(mount(), acting(ctx.org_id, :viewer)))
    end

    test "nobody acting: false", _ctx do
      refute TenantActor.admin?(%{assigns: %{acting_scope: nil, samen_mount: mount()}})
      refute TenantActor.member?(%{assigns: %{acting_scope: nil}})
    end
  end
end
