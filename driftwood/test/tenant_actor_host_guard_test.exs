defmodule Driftwood.TenantActorHostGuardTest do
  @moduledoc """
  The host half of `Samen.Web.TenantActorGuardTest`: the request-path sites in `driftwood/lib` that act with a role
  nobody resolved (a fixed `:member`), counted with the same detectors (`Samen.Web.TenantActor.Guard`) and held to
  an EXACT baseline. A new site fails; a converted site must lower its entry.

    * `driftwood_web/broker_live.ex` builds the broker landing page's actor by hand (`id: "broker:<org>"`, a
      literal `role: :member`): the `/broker` landing page is not converted yet.

  The other hand-spelled roles are SYSTEM contexts (no request path reaches them), listed by file and count so a new
  one is a visible edit: the seeds (`seeds.ex`, `operator_seeds.ex`: org-level actors and membership rows), the
  dispatch worker, the crypto-shred game day and the dogfood scenario. An id-less `%{org_id: o, role: :admin}` counts.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.TenantActor.Guard

  @root Path.expand("../lib", __DIR__)

  @literal_actors %{
    "driftwood_web/broker_live.ex" => 1,
    "driftwood/seeds.ex" => 18,
    "driftwood/operator_seeds.ex" => 11,
    "driftwood/jobs/dispatch_worker.ex" => 1,
    "driftwood/crypto_shred_gameday.ex" => 1,
    "driftwood/dogfood_scenario.ex" => 2
  }

  test "no implicit fixed-role scope call, and no escape hatch, in the host" do
    assert Guard.scan(@root) == %{}
    assert Guard.scan(@root, &Guard.escape_hatches/1) == %{}
  end

  test "the literal tenant actor maps are exactly the listed request-path sites" do
    assert Guard.scan(@root, &Guard.literal_actors/1) == @literal_actors,
           "a literal role (`%{org_id:, role: :atom}`, `%{actor | role: :atom}`, `Map.put(actor, :role, :atom)`) acts with a role nobody resolved: derive it with " <>
             "`Samen.Web.TenantActor.scope/3`, or lower this entry when the site is converted"
  end

  test "non-vacuity: the detectors see this host's tree" do
    assert Path.wildcard(Path.join(@root, "**/*.ex")) |> length() > 20
    assert map_size(Guard.scan(@root, &Guard.literal_actors/1)) == 6
  end
end
