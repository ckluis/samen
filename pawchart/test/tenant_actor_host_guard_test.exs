defmodule PawChart.TenantActorHostGuardTest do
  @moduledoc """
  The host half of `Samen.Web.TenantActorGuardTest`: the request-path sites in `pawchart/lib` that act with a role
  nobody resolved (a fixed `:member`), counted with the same detectors (`Samen.Web.TenantActor.Guard`) and held to
  an EXACT baseline. A new site fails; a converted site must lower its entry.

  The clinic landing page acts as the signed-in person (`Samen.Web.TenantActor`). The hand-spelled roles are SYSTEM contexts (seeds: org-level
  actors and membership rows), listed by file and count so a new one is a visible edit. An id-less
  `%{org_id: o, role: :admin}` counts.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.TenantActor.Guard

  @root Path.expand("../lib", __DIR__)

  @implicit %{}
  @literal_actors %{
    "pawchart/seeds.ex" => 8,
    "pawchart/operator_seeds.ex" => 11
  }

  test "the implicit fixed-role scope calls are exactly the listed request-path sites, and there is no escape hatch" do
    assert Guard.scan(@root) == @implicit,
           "an implicit `Mount.scope/2` acts as a fixed :member: derive the actor with `Samen.Web.TenantActor.scope/3`, " <>
             "or lower this entry when the site is converted"

    assert Guard.scan(@root, &Guard.escape_hatches/1) == %{}
  end

  test "the literal tenant actor maps are exactly the listed request-path sites" do
    assert Guard.scan(@root, &Guard.literal_actors/1) == @literal_actors
  end

  test "non-vacuity: the detectors see this host's tree" do
    assert Path.wildcard(Path.join(@root, "**/*.ex")) |> length() > 20
    assert Guard.scan(@root, &Guard.literal_actors/1) != %{}

    # the implicit-call detector fires on a modeled fixed-role call, and the converted clinic page is clean
    assert Guard.implicit_calls("def f(socket), do: Mount.scope(socket.assigns.samen_mount, socket.assigns.org_id)") > 0
    clinic = File.read!(Path.join(@root, "pawchart_web/clinic_live.ex"))
    assert Guard.implicit_calls(clinic) == 0
  end
end
