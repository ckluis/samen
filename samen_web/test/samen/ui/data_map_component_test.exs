defmodule Samen.UI.DataMapComponentTest do
  @moduledoc """
  Unit proofs for the data-map ERD renderer (`Samen.UI.DataMap`, issue #97) against a
  hand-built `Samen.DataMap` map, in isolation from any host:

    * RANK — a parent (the side a `belongs_to` names) is drawn ABOVE its child.
    * STUB — a table in ANOTHER domain that an edge reaches is drawn as a dashed stub that
      links to that domain's page (the cross-domain seam is never dropped).
    * LONELY — a table with no declared edge sits in a band BELOW the graph.
    * GUTTER — an edge that skips a row is routed up a column gutter, never through a box.
    * NO-JS — the ERD is plain inline SVG with `<a href>` links; no `phx-` hook.
    * DETERMINISM — the same map yields byte-identical geometry and markup.
    * PII — a vault-routed field renders its NAME with a lock; the renderer has no value.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.UI.DataMap

  defp field(name, opts \\ []) do
    %{
      name: name,
      column: "x_" <> name,
      type: Keyword.get(opts, :type, "String"),
      pii: Keyword.get(opts, :pii, false),
      universal: name in ~w(id org_id inserted_at updated_at),
      references: Keyword.get(opts, :references)
    }
  end

  defp table(resource, domain, fields) do
    %{
      resource: resource,
      name: resource |> String.split(".") |> List.last(),
      table_name: resource |> String.split(".") |> List.last() |> String.downcase(),
      domain: domain,
      domain_module: "App." <> String.capitalize(domain),
      layer: :app,
      fields: [field("id"), field("org_id") | fields],
      pii_count: Enum.count(fields, & &1.pii),
      org_scoped: true,
      anchor: false
    }
  end

  defp edge(from, to, name, via) do
    %{from: from, to: to, name: name, type: :belongs_to, via: via, through: nil}
  end

  # crm: Company ← Opportunity ← Attachment, Attachment → Company directly (skips a row),
  #      Person → Company (with PII), Note (no edges).
  # freight: Driver → crm.Company (cross-domain).
  defp fixture do
    tables =
      Map.new(
        [
          table("App.Crm.Company", "crm", [field("name")]),
          table("App.Crm.Person", "crm", [
            field("company_id", references: "App.Crm.Company"),
            field("full_name", pii: true, type: "VaultField")
          ]),
          table("App.Crm.Opportunity", "crm", [field("company_id", references: "App.Crm.Company")]),
          table("App.Crm.Attachment", "crm", [
            field("company_id", references: "App.Crm.Company"),
            field("opportunity_id", references: "App.Crm.Opportunity")
          ]),
          table("App.Crm.Note", "crm", [field("body")]),
          table("App.Freight.Driver", "freight", [
            field("carrier_id", references: "App.Crm.Company")
          ])
        ],
        &{&1.resource, &1}
      )

    edges =
      [
        edge("App.Crm.Person", "App.Crm.Company", "company", "company_id"),
        edge("App.Crm.Opportunity", "App.Crm.Company", "company", "company_id"),
        edge("App.Crm.Attachment", "App.Crm.Company", "company", "company_id"),
        edge("App.Crm.Attachment", "App.Crm.Opportunity", "opportunity", "opportunity_id"),
        edge("App.Freight.Driver", "App.Crm.Company", "carrier", "carrier_id")
      ]
      |> Enum.map(fn e ->
        Map.merge(e, %{
          from_domain: tables[e.from].domain,
          to_domain: tables[e.to].domain,
          external: false
        })
      end)

    domains =
      for {slug, name} <- [{"crm", "CRM"}, {"freight", "Freight"}] do
        ts = tables |> Map.values() |> Enum.filter(&(&1.domain == slug))

        %{
          slug: slug,
          name: name,
          module: "App." <> String.capitalize(slug),
          layer: :app,
          tables: ts |> Enum.map(& &1.resource) |> Enum.sort(),
          table_count: length(ts),
          pii_count: 0,
          links_out: [],
          links_in: []
        }
      end

    %{domains: domains, tables: tables, edges: edges}
  end

  defp node!(g, resource),
    do: Enum.find(g.nodes, &(&1.resource == resource)) || flunk("no node #{resource}")

  test "RANK: a parent is drawn above every child that names it" do
    g = DataMap.erd_layout(fixture(), "crm")
    company = node!(g, "App.Crm.Company")

    for child <- ~w(App.Crm.Person App.Crm.Opportunity App.Crm.Attachment) do
      assert node!(g, child).y > company.y, "#{child} must sit below Company"
    end

    assert node!(g, "App.Crm.Attachment").y > node!(g, "App.Crm.Opportunity").y
  end

  test "STUB: a cross-domain table is a dashed stub linking to its own domain page" do
    g = DataMap.erd_layout(fixture(), "crm")
    driver = node!(g, "App.Freight.Driver")
    assert driver.kind == :stub
    assert driver.domain == "freight"

    html =
      render_component(&DataMap.erd/1,
        map: fixture(),
        domain: "crm",
        base_path: "/operator/data-map"
      )

    assert html =~ ~s(href="/operator/data-map/freight")
    assert html =~ "in Freight →"

    # ANTI-VACUITY: the freight page draws Company as the stub, not Driver.
    assert node!(DataMap.erd_layout(fixture(), "freight"), "App.Crm.Company").kind == :stub
    assert node!(DataMap.erd_layout(fixture(), "freight"), "App.Freight.Driver").kind == :table
  end

  test "LONELY: a table with no declared edge sits below the whole graph" do
    g = DataMap.erd_layout(fixture(), "crm")
    note = node!(g, "App.Crm.Note")
    linked = Enum.reject(g.nodes, &(&1.resource == "App.Crm.Note"))
    assert Enum.all?(linked, &(&1.y < note.y))
  end

  test "GUTTER: an edge that skips a row never crosses a box it does not connect" do
    g = DataMap.erd_layout(fixture(), "crm")

    skip =
      Enum.find(g.edges, &(&1.from == "App.Crm.Attachment" and &1.to == "App.Crm.Company")) ||
        flunk("missing Attachment → Company edge")

    # The gutter route is a rounded polyline (one Q per corner), not a single cubic.
    assert length(Regex.scan(~r/ Q/, skip.d)) >= 4

    # Its vertical gutter run lies outside every box's horizontal extent.
    {gx, _} = Float.parse(skip.lx)
    gx = gx - 6
    assert Enum.all?(g.nodes, fn n -> gx < n.x or gx > n.x + n.w end)

    # ANTI-VACUITY: an adjacent-row edge is still a single cubic.
    adjacent = Enum.find(g.edges, &(&1.from == "App.Crm.Person"))
    assert adjacent.d =~ " C"
    refute adjacent.d =~ " Q"
  end

  test "NO-JS: the ERD is inline SVG with plain links and no LiveView hook" do
    html = render_component(&DataMap.erd/1, map: fixture(), domain: "crm")
    assert html =~ "<svg"
    refute html =~ "phx-"
  end

  test "DETERMINISM: the same map renders byte-identical geometry and markup" do
    assert DataMap.erd_layout(fixture(), "crm") == DataMap.erd_layout(fixture(), "crm")

    a = render_component(&DataMap.erd/1, map: fixture(), domain: "crm")
    b = render_component(&DataMap.erd/1, map: fixture(), domain: "crm")
    assert a == b
  end

  test "PII: a vault-routed field renders its name with a lock and the PII row style" do
    html = render_component(&DataMap.erd/1, map: fixture(), domain: "crm")
    assert html =~ "dmap-field-pii"
    assert html =~ "🔒 full_name"
    # The universal columns are collapsed into the footer, not listed per box.
    refute html =~ ">org_id<"
    assert html =~ "id · org_id · timestamps"
  end

  test "an unknown domain lays out an empty canvas rather than raising" do
    g = DataMap.erd_layout(fixture(), "nope")
    assert g.nodes == [] and g.edges == []
  end
end
