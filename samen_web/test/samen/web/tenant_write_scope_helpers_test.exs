defmodule Samen.Web.TenantWriteScopeHelpersTest do
  @moduledoc """
  The tenant-admin write helpers (`Billing.Reads.write_scope/3`, `Marketing.Reads.write_scope/3`,
  `Support.KbReads.write_scope/3`, `Flags.Reads.write_scope/3`) never hand an admin role to the operator plane: on an
  operator-plane mount the Billing, Marketing and Knowledge-base helpers answer the read-only scope; the Flags helper is the
  operator workspace's own (a mount of `scope_kind: :operator`) and answers the read-only scope on every other mount, because
  a tenant page writes with `TenantActor.write_scope/3`.

  Every refusal is paired with the elevation the helper still gives where it is theirs to give.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.{Mount, Plane}
  alias Samen.Web.Billing.Reads, as: BillingReads
  alias Samen.Web.Flags.Reads, as: FlagsReads
  alias Samen.Web.Marketing.Reads, as: MarketingReads
  alias Samen.Web.Support.KbReads

  @org "11111111-1111-1111-1111-111111111111"

  defp tenant(kind, ns), do: Mount.new(kind, ns, Samen.WebTest.Repo)
  defp operator_plane(kind, ns), do: Mount.new(kind, ns, Samen.WebTest.Repo, plane: Plane.operator("op-1", @org, "sess-1"))

  defp assert_read_only(scope) do
    assert %Samen.Scope{actor: %{read_only: true, role: role}} = scope
    refute Samen.Scope.Role.at_least?(role, :member)
  end

  defp assert_admin(scope), do: assert(%Samen.Scope{actor: %{role: :admin}} = scope)

  test "billing, marketing and knowledge-base helpers: read-only on the operator plane, the posture's admin on a tenant mount" do
    for {helper, kind, ns} <- [
          {&BillingReads.write_scope/2, :billing, Samen.WebTest.Billing},
          {&MarketingReads.write_scope/2, :marketing, Samen.WebTest.Marketing},
          {&KbReads.write_scope/2, :kb, Samen.WebTest.Cms}
        ] do
      assert_read_only(helper.(operator_plane(kind, ns), @org))
      # positive control: the disarmed dev posture keeps its admin on a tenant mount
      assert_admin(helper.(tenant(kind, ns), @org))
    end
  end

  test "the flags helper elevates the operator workspace's own mount and nobody else's" do
    operator_workspace = Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo, plane: Plane.tenant())
    assert_admin(FlagsReads.write_scope(operator_workspace, @org))

    assert_read_only(FlagsReads.write_scope(tenant(:flags, Samen.WebTest.Primitives), @org))
    assert_read_only(FlagsReads.write_scope(operator_plane(:flags, Samen.WebTest.Primitives), @org))
  end
end
