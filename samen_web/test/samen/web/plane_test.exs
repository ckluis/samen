defmodule Samen.Web.PlaneTest do
  @moduledoc """
  Unit tests for `Samen.Web.Plane`: the two planes produce the exact actors the resolver
  reads (`plane: :tenant` clear, `plane: :operator` + impersonation masked). The plane masks
  nothing itself — it produces the actor whose `:plane` key drives `Samen.Api.PiiResolution`.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Plane

  test "tenant plane produces a tenant actor (plane: :tenant, kind: :tenant)" do
    scope = Plane.scope(Plane.tenant(), "org-1")
    actor = scope.actor

    assert actor.plane == :tenant
    assert actor.kind == :tenant
    assert actor.org_id == "org-1"
    assert actor.id == "broker:org-1"
    refute Map.has_key?(actor, :impersonation)
  end

  test "operator plane produces an impersonation actor (plane: :operator + impersonation)" do
    plane = Plane.operator("op-7", "target-org", "sess-x")
    scope = Plane.scope(plane, "ignored-when-target-set")
    actor = scope.actor

    assert actor.plane == :operator
    assert actor.kind == :operator
    # The operator reads the TARGET tenant org's data.
    assert actor.org_id == "target-org"
    assert actor.id == "operator:op-7"
    assert actor.impersonation[:session_id] == "sess-x"
  end

  test "the resolver's plane_of reads exactly the actor's :plane key" do
    tenant_actor = Plane.scope(Plane.tenant(), "o").actor
    operator_actor = Plane.scope(Plane.operator("op", "o"), "o").actor

    # The resolver keys masking off actor.plane — assert the contract the resolver depends on.
    assert Map.get(tenant_actor, :plane) == :tenant
    assert Map.get(operator_actor, :plane) == :operator
  end
end
