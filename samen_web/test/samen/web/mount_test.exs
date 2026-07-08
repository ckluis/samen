defmodule Samen.Web.MountTest do
  @moduledoc """
  Unit tests for the `Samen.Web.Mount` parameterization struct: resource derivation by the
  ADR-004 `Module.concat(namespace, Name)` convention, and lossless session round-trip
  (atoms/strings only — safe to sign into a cookie).
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Mount
  alias Samen.Web.Plane

  test "resource/2 derives a host resource by Module.concat(namespace, name)" do
    mount = Mount.new(:crm, Some.Host.Crm, Some.Host.Repo)

    assert Mount.resource(mount, Person) == Some.Host.Crm.Person
    assert Mount.resource(mount, Company) == Some.Host.Crm.Company

    # A DIFFERENT host derives DIFFERENT modules from the SAME code — the whole point.
    other = Mount.new(:billing, Other.App.Billing, Other.App.Repo)
    assert Mount.resource(other, Customer) == Other.App.Billing.Customer
  end

  test "domain defaults to namespace; plane defaults to tenant" do
    mount = Mount.new(:crm, Some.Host.Crm, Some.Host.Repo)
    assert mount.domain == Some.Host.Crm
    assert mount.plane == %Plane{kind: :tenant}
  end

  test "to_session/1 -> from_session/1 round-trips losslessly (tenant plane)" do
    mount =
      Mount.new(:crm, Some.Host.Crm, Some.Host.Repo,
        labels: %{title: "Blue Ridge", glyph: "B", crumb_root: "Blue Ridge Logistics"}
      )

    round = mount |> Mount.to_session() |> Mount.from_session()

    assert round.scope_kind == :crm
    assert round.namespace == Some.Host.Crm
    assert round.repo == Some.Host.Repo
    assert round.domain == Some.Host.Crm
    assert round.plane == %Plane{kind: :tenant}
    assert round.labels[:title] == "Blue Ridge"
    assert round.labels[:glyph] == "B"
  end

  test "to_session/1 -> from_session/1 round-trips the operator plane" do
    mount =
      Mount.new(:support, Some.Host.Support, Some.Host.Repo,
        plane: Plane.operator("op-9", "org-abc", "sess-1")
      )

    round = mount |> Mount.to_session() |> Mount.from_session()

    assert round.plane.kind == :operator
    assert round.plane.operator_id == "op-9"
    assert round.plane.target_org_id == "org-abc"
    assert round.plane.impersonation[:session_id] == "sess-1"
  end

  test "the session map contains only strings/maps (no PII, no live struct) — cookie-safe" do
    session = Mount.new(:crm, Some.Host.Crm, Some.Host.Repo) |> Mount.to_session()

    for {k, v} <- session do
      assert is_binary(k)
      assert is_binary(v) or is_map(v) or is_nil(v)
    end
  end

  test "label/3 returns the override or the neutral default" do
    bare = Mount.new(:crm, Some.Host.Crm, Some.Host.Repo)
    assert Mount.label(bare, :title, "Workspace") == "Workspace"

    branded = Mount.new(:crm, Some.Host.Crm, Some.Host.Repo, labels: %{title: "Acme"})
    assert Mount.label(branded, :title, "Workspace") == "Acme"
  end
end
