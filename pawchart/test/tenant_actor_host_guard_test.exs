defmodule PawChart.TenantActorHostGuardTest do
  @moduledoc """
  The host half of `Samen.Web.TenantActorGuardTest`: the request-path sites in `pawchart/lib` that act with a role
  nobody resolved (a fixed `:member`), counted with the same detectors (`Samen.Web.TenantActor.Guard`) and held to
  an EXACT baseline. A new site fails; a converted site must lower its entry.

    * `pawchart_web/clinic_live.ex` calls `Mount.scope/2` twice (the clinic landing page: load and event).
    * `pawchart_web/clinic_reads.ex` builds the clinic actor by hand (`id: "clinic:<org>"`, a literal `role: :member`).

  The clinic landing page is not converted yet; the other callers in this app (seeds, the clinic domain) are system
  contexts and are not spelled in a form the detectors match.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.TenantActor.Guard

  @root Path.expand("../lib", __DIR__)

  @implicit %{"pawchart_web/clinic_live.ex" => 2}
  @literal_actors %{"pawchart_web/clinic_reads.ex" => 1}

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
    assert Guard.scan(@root) != %{}
  end
end
