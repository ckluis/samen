defmodule Samen.Web.ReadsGeoTest do
  @moduledoc """
  The GENERIC map-marker primitive (`Samen.Web.Reads.geo_markers!/3`, G7/T55) — the framework
  building block the `Samen.UI.map/1` tile consumes. Each proof is anti-tautology (a positive
  control anchors every guard):

    * PROJECTION — seeded coordinates project to the RIGHT deterministic SVG positions.
    * ORG-SCOPE — a 2-org seed: org B's points NEVER enter org A's map (sabotage-refutable —
      org B genuinely holds plottable rows, proven absent from A's geo set).
    * BOUNDING — an over-cap geo dataset CAPS at `max_markers` (not all N plotted), sets
      `capped: true`, and the shown count equals the cap (a 100k-row table can't OOM the DOM).
    * COORD MASKING (INV-1) — plotting a coordinate FROM a vault-routed (🔒) field is REFUSED
      (`MaskedCoordinateError`); a non-vaulted twin plots fine (the refutation control).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Factory
  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.Web.Reads.MaskedCoordinateError
  alias Samen.Web.GeoSet
  alias Samen.WebTest.Crm.Person

  # lat/lng carried on the plain, non-PII `job_title` string ("lat,lng") — a plottable,
  # NON-secret facet (the `custom` Tier-1 bag rejects unregistered keys, so it is unsuitable).
  defp seed_place!(org_id, name, lat, lng) do
    Factory.create!(
      Person,
      Map.merge(Factory.person("Geo", name), %{
        display_name: name,
        org_id: org_id,
        job_title: "#{lat},#{lng}"
      }),
      Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)
    )
  end

  defp coord(record, idx) do
    case String.split(record.job_title || "", ",") do
      parts when length(parts) == 2 -> parts |> Enum.at(idx) |> String.to_float()
      _ -> nil
    end
  end

  defp lat_fun, do: fn p -> coord(p, 0) end
  defp lng_fun, do: fn p -> coord(p, 1) end

  defp markers(org_id, opts \\ []) do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, org_id)

    Person
    |> Reads.geo_markers!(
      Keyword.merge(
        [scope: scope, lat: lat_fun(), lng: lng_fun(), label: :display_name],
        opts
      )
    )
  end

  test "PROJECTION: seeded coordinates project to the right deterministic SVG positions" do
    org = Ash.UUID.generate()
    seed_place!(org, "Null Island", 0.0, 0.0)
    seed_place!(org, "Manhattan", 40.0, -74.0)

    geo = markers(org)
    by_label = Map.new(geo.markers, &{&1.label, &1})

    # (0,0) → canvas centre (180,90); (40,-74) → (106,50). See Samen.Web.Geo.Projection.
    assert by_label["Null Island"].x == 180.0
    assert by_label["Null Island"].y == 90.0
    assert by_label["Manhattan"].x == 106.0
    assert by_label["Manhattan"].y == 50.0
    assert %GeoSet{} = geo
    refute geo.capped
  end

  test "ORG-SCOPE: org B's points never enter org A's map (2-org, sabotage-refutable)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    seed_place!(org_a, "A-Site", 10.0, 10.0)
    # org B genuinely holds a plottable row (the refutation control) — it must NOT appear in A.
    seed_place!(org_b, "B-Secret-Site", 20.0, 20.0)

    a = markers(org_a)
    labels_a = Enum.map(a.markers, & &1.label)

    assert "A-Site" in labels_a
    refute "B-Secret-Site" in labels_a
    assert length(a.markers) == 1

    # Positive control: org B's OWN map DOES hold B's row (proving the seed is plottable, so
    # its absence from A is org-scope, not an empty seed).
    b = markers(org_b)
    assert "B-Secret-Site" in Enum.map(b.markers, & &1.label)
  end

  test "BOUNDING: an over-cap geo dataset caps at max_markers (not all N plotted) and flags capped" do
    org = Ash.UUID.generate()
    for i <- 1..7, do: seed_place!(org, "P#{i}", i * 1.0, i * 1.0)

    geo = markers(org, max_markers: 3)

    assert geo.max_markers == 3
    assert length(geo.markers) == 3
    assert geo.shown == 3
    assert geo.capped
  end

  test "BOUNDING: a request under the cap is not flagged capped" do
    org = Ash.UUID.generate()
    for i <- 1..2, do: seed_place!(org, "P#{i}", i * 1.0, i * 1.0)

    geo = markers(org, max_markers: 10)
    assert length(geo.markers) == 2
    refute geo.capped
    assert geo.capped_count == 0
  end

  test "COORD MASKING: plotting a coordinate from a vault-routed (🔒) field is REFUSED" do
    org = Ash.UUID.generate()
    seed_place!(org, "V", 1.0, 1.0)

    mount = build_mount(:crm)
    scope = Mount.scope(mount, org)
    person = Person

    # full_name is vault-routed → a precise coordinate must not be plotted from the vault.
    assert_raise MaskedCoordinateError, fn ->
      Reads.geo_markers!(person, scope: scope, lat: :full_name, lng: lng_fun())
    end

    assert_raise MaskedCoordinateError, fn ->
      Reads.geo_markers!(person, scope: scope, lat: lat_fun(), lng: :full_name)
    end
  end

  test "COORD MASKING refutation: a NON-vaulted coordinate field is allowed (the control)" do
    org = Ash.UUID.generate()
    seed_place!(org, "OK", 1.0, 1.0)

    mount = build_mount(:crm)
    scope = Mount.scope(mount, org)
    person = Person

    # :job_title is a non-vaulted attribute — no refusal (proves the guard keys on the VAULT
    # flag, not a blanket "any atom is refused"). Non-numeric values simply yield nil coords.
    geo = Reads.geo_markers!(person, scope: scope, lat: :job_title, lng: :job_title, label: :display_name)
    assert %GeoSet{} = geo
    assert length(geo.markers) == 1
  end
end
