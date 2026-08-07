defmodule Samen.Web.MountFleetLabelTest do
  @moduledoc """
  T83 / J3 — the CLOSED mount label whitelist carries the fleet seams (ADR-044 §6.3a #2).

  `Samen.Web.Mount` enumerates a closed `@label_keys` whitelist. A cockpit mount carries its
  per-product authorization + name-resolution seams (`:fleet_authority` / `:fleet_resolution`) as
  mount labels; if a key is NOT whitelisted it is silently dropped at `from_session/1` and the
  gate reads `nil` — the landmine §6.3a #2 names: it fails OPEN-LOOKING (a nil label), not loudly.
  So the property is a TEST, not an ADR sentence.

  SABOTAGE-REFUTABLE: remove `fleet_authority`/`fleet_resolution` from the whitelist and this
  suite fails (the labels vanish across the session round-trip) — proven by
  `scripts/sabotages/120-t83-j3-mount-fleet-label-whitelist-drop.patch`.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Mount

  @fleet_authority {Samen.Fleet.Authz, :roles_for, [:app]}
  @fleet_resolution {Samen.Fleet.Resolution, :scope_of, [:app]}

  test "both fleet label keys are in the closed whitelist" do
    assert :fleet_authority in Mount.label_keys()
    assert :fleet_resolution in Mount.label_keys()
  end

  test "fleet labels SURVIVE a to_session/from_session round-trip (not silently dropped)" do
    mount =
      Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
        labels: %{fleet_authority: @fleet_authority, fleet_resolution: @fleet_resolution}
      )

    round_tripped = mount |> Mount.to_session() |> Mount.from_session()

    assert Mount.label(round_tripped, :fleet_authority, nil) == @fleet_authority,
           "fleet_authority label was dropped across the session round-trip — the gate would read nil"

    assert Mount.label(round_tripped, :fleet_resolution, nil) == @fleet_resolution,
           "fleet_resolution label was dropped across the session round-trip — resolution would fail closed unexpectedly"
  end

  test "an UNWHITELISTED garbage label key is still rejected (whitelist ≠ blanket to_string mint)" do
    # The whitelist must not have turned into a blanket atomizer — a cookie-injected key that
    # was never compiled as an atom still raises rather than minting.
    raw = %{
      "scope_kind" => "operator",
      "namespace" => "Elixir.Samen.WebTest.Operator",
      "repo" => "Elixir.Samen.WebTest.Repo",
      "domain" => "Elixir.Samen.WebTest.Operator",
      "plane" => Samen.Web.Plane.to_session(Samen.Web.Plane.tenant()),
      "labels" => %{"totally_unknown_cookie_label_xyz" => "x"}
    }

    assert_raise ArgumentError, fn -> Mount.from_session(raw) end
  end
end
