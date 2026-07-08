defmodule Samen.Web.OperatorContextTest do
  @moduledoc """
  Unit tests for the `Samen.Web.Operator` context (ADR-010 §3.2) and the `samen_operator_routes`
  router macro (§7.2): operator org-id resolution, the operator-org TENANT-plane scope (the
  identity-line hinge — clear by construction), and the one-line host mount.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.{Mount, Operator, Plane}

  defp operator_mount(labels) do
    Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
      plane: Plane.tenant(),
      labels: labels
    )
  end

  test "org_id/1 resolves the explicit :operator_org_id label first" do
    mount = operator_mount(%{operator_org_id: "op-123"})
    assert Operator.org_id(mount) == "op-123"
  end

  test "scope/1 is the operator org on the TENANT plane (clear by construction)" do
    mount = operator_mount(%{operator_org_id: "op-123"})
    scope = Operator.scope(mount)

    # The identity-line hinge: org_id = operator org, plane = :tenant → PiiResolution clears
    # own-org PII. This is the SAME tenant-plane actor ADR-009 tests, scoped to the operator org.
    assert scope.actor.org_id == "op-123"
    assert scope.actor.plane == :tenant
    assert scope.actor.kind == :tenant
  end

  test "impersonation_plane/2 crosses to the tenant's masked world (operator plane)" do
    mount = operator_mount(%{operator_org_id: "op-123"})
    plane = Operator.impersonation_plane(mount, "tenant-999", "sess-1")

    # Crossing from the clear account to the masked tenant world is the ADR-009 operator plane.
    assert plane.kind == :operator
    assert plane.operator_id == "op-123"
    assert plane.target_org_id == "tenant-999"
  end

  # A real host router that mounts the operator workspace via the macro — if the macro is
  # broken, THIS MODULE FAILS TO COMPILE, the strongest test of expansion.
  defmodule HostRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_operator_routes(Some.Host.Operator, repo: Some.Host.Repo, operator_org_id: "op-xyz")
    end

    scope "/agg" do
      samen_operator_routes(Some.Host.Operator2,
        repo: Some.Host.Repo,
        path: "/ops",
        include_aggregate: true,
        session_name: :samen_operator_agg
      )
    end
  end

  test "samen_operator_routes registers the operator workspace routes (aggregate off by default)" do
    paths = HostRouter.__routes__() |> Enum.map(& &1.path)

    assert "/operator/accounts" in paths
    assert "/operator/billing" in paths
    assert "/operator/desk" in paths
    # aggregate is NOT mounted by default (a host usually wires its own vertical-shaped loader).
    refute "/operator/aggregate" in paths
  end

  test "samen_operator_routes with include_aggregate: true mounts the aggregate page too" do
    paths = HostRouter.__routes__() |> Enum.map(& &1.path)

    assert "/agg/ops/accounts" in paths
    assert "/agg/ops/aggregate" in paths
  end

  test "__operator_labels__/2 threads the operator_org_id onto the labels" do
    assert Samen.Web.Router.__operator_labels__(%{}, "op-1") == %{operator_org_id: "op-1"}
    assert Samen.Web.Router.__operator_labels__(%{title: "x"}, nil) == %{title: "x"}
  end
end
