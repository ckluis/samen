defmodule Driftwood.TenantActorHostGuardTest do
  @moduledoc """
  The host half of `Samen.Web.TenantActorGuardTest`: the request-path sites in `driftwood/lib` that act with a role
  nobody resolved (a fixed `:member`), counted with the same detectors (`Samen.Web.TenantActor.Guard`) and held to
  an EXACT baseline. A new site fails; a converted site must lower its entry.

    * `driftwood_web/broker_live.ex` builds the broker landing page's actor by hand (`id: "broker:<org>"`, a
      literal `role: :member`): the `/broker` landing page is not converted yet.

  The other `Mount.scope`/`system_scope` callers in this app (seeds, the dispatch worker, the crypto-shred
  game day) are system contexts and are not spelled in a form the detectors match; there is none to list.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.TenantActor.Guard

  @root Path.expand("../lib", __DIR__)

  @literal_actors %{"driftwood_web/broker_live.ex" => 1}

  test "no implicit fixed-role scope call, and no escape hatch, in the host" do
    assert Guard.scan(@root) == %{}
    assert Guard.scan(@root, &Guard.escape_hatches/1) == %{}
  end

  test "the literal tenant actor maps are exactly the listed request-path sites" do
    assert Guard.scan(@root, &Guard.literal_actors/1) == @literal_actors,
           "a literal `%{id:, org_id:, role: :atom}` acts with a role nobody resolved: derive it with " <>
             "`Samen.Web.TenantActor.scope/3`, or lower this entry when the site is converted"
  end

  test "non-vacuity: the detectors see this host's tree" do
    assert Path.wildcard(Path.join(@root, "**/*.ex")) |> length() > 20
    assert map_size(Guard.scan(@root, &Guard.literal_actors/1)) == 1
  end
end
