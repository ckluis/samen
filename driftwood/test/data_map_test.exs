defmodule Driftwood.DataMapTest do
  @moduledoc """
  Issue #97 — the data map (`Samen.DataMap` + `/operator/data-map`) over a REAL host.

    * PARITY — the map's tables are exactly the committed `schema.dict.json` catalog's
      tables, and its edges come from the dict's `relationships` (one source, no drift).
    * DECLARED ONLY (D5) — a declared `belongs_to` is an edge; an undeclared `*_id` scalar
      (Work.Task `owner_id`) and a polymorphic subject anchor (Docs.Doc `subject_id`) are
      NOT — the anchor is flagged `anchor: true` instead.
    * LAYERS — the token-blind aggregate domain is classified `:aggregate` from its
      `AggregateActorOnly` policy, the framework substrate `:framework`, the rest `:app`.
    * GATE — the page rides the operator live_session: an armed tenant-user session is
      refused (302 → /login); a roster operator gets the map (positive control).
    * METADATA ONLY — the page renders PII field NAMES and never a seeded PII value.
  """
  use Driftwood.DataCase, async: false

  import Phoenix.ConnTest

  @endpoint DriftwoodWeb.Endpoint

  @tenant_user "11111111-0000-4000-8000-0000000000t9"
  @operator_user "0f000000-0000-4000-8000-000000000op1"
  @seeded_email "marlene.okafor@blueridge.example"

  describe "Samen.DataMap.build/1 over driftwood" do
    setup do
      {:ok, map: Samen.DataMap.build()}
    end

    test "PARITY: the map's tables are exactly the committed catalog's tables", %{map: map} do
      committed =
        Path.expand("../schema.dict.json", __DIR__) |> File.read!() |> Jason.decode!()

      assert map.tables |> Map.keys() |> Enum.sort() ==
               committed["tables"] |> Enum.map(& &1["resource"]) |> Enum.sort()

      committed_edges =
        for t <- committed["tables"],
            r <- t["relationships"],
            r["type"] == "belongs_to",
            do: {t["resource"], r["destination"], r["source_attribute"]}

      map_edges = for e <- map.edges, e.type == :belongs_to, do: {e.from, e.to, e.via}
      assert Enum.sort(map_edges) == Enum.sort(committed_edges)
    end

    test "DECLARED ONLY: belongs_to is an edge; an undeclared *_id or a subject anchor is not",
         %{map: map} do
      assert Enum.any?(
               map.edges,
               &(&1.from == "Driftwood.Freight.Driver" and &1.to == "Driftwood.Crm.Company" and
                   &1.via == "carrier_id")
             )

      task = map.tables["Driftwood.Work.Task"]
      assert Enum.any?(task.fields, &(&1.name == "owner_id"))
      refute Enum.any?(map.edges, &(&1.from == "Driftwood.Work.Task" and &1.via == "owner_id"))

      doc = map.tables["Driftwood.Docs.Doc"]
      assert doc.anchor
      refute Enum.any?(map.edges, &(&1.from == "Driftwood.Docs.Doc" and &1.via == "subject_id"))

      # ANTI-VACUITY: not every table is an anchor.
      refute map.tables["Driftwood.Crm.Person"].anchor
    end

    test "LAYERS: aggregate from its policy, framework from Samen.*, the rest app", %{map: map} do
      assert map.tables["Driftwood.Aggregate.MrrByTier"].layer == :aggregate
      assert map.tables["Samen.Replay.Frame"].layer == :framework
      assert map.tables["Driftwood.Crm.Person"].layer == :app

      assert Samen.DataMap.domain(map, "aggregate").layer == :aggregate
      assert Samen.DataMap.domain(map, "crm").links_in |> Map.new() |> Map.get("freight") >= 1
    end

    test "PII flags come from the vault declaration", %{map: map} do
      person = map.tables["Driftwood.Crm.Person"]
      pii = for f <- person.fields, f.pii, do: f.name
      assert "full_name" in pii and "emails" in pii
      refute "company_id" in pii
      assert person.pii_count == length(pii)
    end
  end

  describe "/operator/data-map" do
    setup do
      start_supervised!(DriftwoodWeb.Endpoint)

      prev_required = Application.get_env(:driftwood, :auth_required?)
      prev_roster = Application.get_env(:driftwood, :operator_roster)
      Application.put_env(:driftwood, :auth_required?, true)
      Application.put_env(:driftwood, :operator_roster, %{@operator_user => :operator_admin})
      Driftwood.OperatorSeeds.seed()

      on_exit(fn ->
        restore(:auth_required?, prev_required)
        restore(:operator_roster, prev_roster)
      end)

      :ok
    end

    defp restore(key, nil), do: Application.delete_env(:driftwood, key)
    defp restore(key, val), do: Application.put_env(:driftwood, key, val)

    defp session_conn(user_id),
      do: build_conn() |> init_test_session(%{"samen_current_user" => user_id})

    test "RED: an armed tenant-user session is refused the data map" do
      for path <- ["/operator/data-map", "/operator/data-map/crm"] do
        conn = get(session_conn(@tenant_user), path)
        assert conn.status == 302, "#{path} must refuse a tenant user"
        refute conn.resp_body =~ "dmap-svg"
      end
    end

    test "POSITIVE CONTROL: an operator gets the overview with every layer" do
      html = session_conn(@operator_user) |> get("/operator/data-map") |> html_response(200)
      assert html =~ ~s(id="layer-app")
      assert html =~ ~s(id="layer-framework")
      assert html =~ ~s(id="layer-aggregate")
      assert html =~ ~s(href="/operator/data-map/crm")
    end

    test "the domain page renders the ERD + field reference, names only, never a value" do
      html = session_conn(@operator_user) |> get("/operator/data-map/crm") |> html_response(200)
      assert html =~ "dmap-svg"
      assert html =~ "🔒 full_name"
      assert html =~ ~s(href="/operator/data-map/freight")
      assert html =~ "fpr_person"
      refute html =~ @seeded_email
    end

    test "an unknown domain renders an explicit not-found state, not a crash" do
      html = session_conn(@operator_user) |> get("/operator/data-map/nope") |> html_response(200)
      assert html =~ ~s(id="unknown-domain")
    end
  end
end
