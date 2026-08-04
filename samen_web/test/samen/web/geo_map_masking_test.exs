defmodule Samen.Web.GeoMapMaskingTest do
  @moduledoc """
  T55 (G7) — per-plane masking on the MAP marker popover (`Samen.UI.map/1`, first client of
  `Samen.Web.Reads.geo_markers!/3`). A marker `label` may render VAULT-ROUTED (🔒) PII
  (`full_name`), so this surface ships the sanctioned three-part `Samen.MaskingCase` proof
  (CLAUDE.md's masking watch-list discipline), the SAME green/red/sabotage shape as the
  file-preview / gallery masking tests:

    * GREEN — the tenant plane renders the vaulted marker label in the CLEAR.
    * RED — the operator (impersonation) plane renders `••••` for the SAME marker: never the
      plaintext, never a `vt_*` vault token (whole-DOM scan).
    * SABOTAGE twins — (1) plane flip: the ONLY difference is the mount's plane (the resolver is
      the gate, not a blanket mask); (2) leak-scan refutability: a modeled raw (unmasked) label
      IS caught by the same scan, so the RED assertion is not vacuous.

  The coordinate axis of INV-1 (a vaulted coordinate is REFUSED, `MaskedCoordinateError`) is
  proven in `reads_geo_test.exs`; this unit covers the LABEL axis.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  import Phoenix.LiveViewTest, only: [render_component: 2]

  require Ash.Query

  alias Samen.Api.PiiResolution
  alias Samen.Factory
  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.WebTest.Crm.Person

  @secret_first "GeoVaultedFirst"
  @secret_last "Geo-Secret-Last"

  defp seed_secret_person!(org_id) do
    Factory.create!(
      Person,
      Map.merge(Factory.person(@secret_first, @secret_last), %{
        display_name: "Public Map Label",
        job_title: "40.0,-74.0",
        org_id: org_id
      }),
      Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), org_id)
    )
  end

  defp coord(record, idx), do: record.job_title |> String.split(",") |> Enum.at(idx) |> String.to_float()

  # Build the map's geo set exactly as a host would: geo_markers! with a :resolve seam that runs
  # PiiResolution on the actor's plane, so the vaulted :full_name label masks per plane.
  defp render_map(mount, org_id) do
    scope = Mount.scope(mount, org_id)
    actor = scope_actor(scope)

    geo =
      Person
      |> Reads.geo_markers!(
        scope: scope,
        lat: fn p -> coord(p, 0) end,
        lng: fn p -> coord(p, 1) end,
        label: :full_name,
        resolve: fn recs -> PiiResolution.resolve(recs, Person, actor, repo: mount.repo) end
      )

    render_component(&Samen.UI.map/1, %{id: "gm", geo_set: geo, show_table: true})
  end

  defp scope_actor(%Samen.Scope{actor: actor}), do: actor
  defp scope_actor(actor), do: actor

  test "GREEN: the tenant plane renders the vaulted marker label in the CLEAR" do
    org_id = Ash.UUID.generate()
    seed_secret_person!(org_id)

    html = render_map(build_mount(:crm), org_id)

    assert html =~ @secret_first
    assert html =~ @secret_last
    refute html =~ "vt_"
    # The non-PII public facet rides along regardless (the pin still plots).
    assert html =~ ~s(class="geo-marker-dot")
  end

  test "RED: the operator plane renders •••• — NEVER plaintext, NEVER a vt_ token" do
    org_id = Ash.UUID.generate()
    seed_secret_person!(org_id)

    html = render_map(build_mount(:crm, plane: :operator, target_org_id: org_id), org_id)

    # Whole-DOM scan: mask present, every plaintext half ABSENT, no vault token anywhere.
    assert_masked_dom!(html, [@secret_first, @secret_last])
    # The pin still plots (masking is per-field, not per-marker) — a masked location is still a dot.
    assert html =~ ~s(class="geo-marker-dot")
  end

  test "SABOTAGE (plane flip): the SAME marker label goes clear on tenant, masked on operator" do
    org_id = Ash.UUID.generate()
    person = seed_secret_person!(org_id)

    at_rest =
      Person
      |> Ash.Query.filter(id == ^person.id)
      |> Ash.Query.ensure_selected([:full_name])
      |> Ash.read_one!(authorize?: false)

    tenant_name = resolve_on_plane(at_rest, Person, :tenant, repo: Samen.WebTest.Repo).full_name
    operator_name = resolve_on_plane(at_rest, Person, :operator, repo: Samen.WebTest.Repo).full_name

    # The only difference is the plane → the resolver is the gate (not a serialize-as-•••• blanket).
    refute match?(%Samen.Masked{}, tenant_name)
    assert to_string(tenant_name) =~ @secret_first
    assert to_string(tenant_name) =~ @secret_last
    assert_plane_masked!(operator_name)
  end

  test "SABOTAGE (leak-scan refutability): a modeled raw label IS caught by the RED scan" do
    # Prove the RED assertion is not vacuous: if the resolver leaked plaintext into the label,
    # the same whole-DOM mask scan would FAIL. Model the leak by rendering the UNMASKED name.
    leaked_geo = %Samen.Web.GeoSet{
      markers: [
        %Samen.Web.GeoSet.Marker{id: "x", lat: 40.0, lng: -74.0, x: 106.0, y: 50.0, label: "#{@secret_first} #{@secret_last}"}
      ],
      shown: 1
    }

    html = render_component(&Samen.UI.map/1, %{id: "leak", geo_set: leaked_geo, show_table: true})

    assert_leak_detected!(html, @secret_first)
  end
end
