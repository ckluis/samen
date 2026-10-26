defmodule Samen.DataMap do
  @moduledoc """
  The **data map** model (issue #97) — the ERD and the architectural separation of a
  host app, built from the SAME catalog `mix samen.catalog.dump` commits.

  Documentation that cannot drift from the code because it IS the code: every table,
  field, PII flag and edge here comes from `Samen.AI.Catalog.dict/1` (the function the
  drift-checked `schema.dict.json` artifact delegates to), and the only thing this
  module adds is *where each table sits* — its domain and its layer — read from the same
  compile-time `Ash.Resource.Info` / `Ash.Policy.Info` metadata.

  ## Layers (the architectural separation)

    * `:app`       — the host's own scope domains (`Driftwood.Crm`, `Driftwood.Billing`…).
    * `:framework` — substrate the framework ships into every host (a domain under
      `Samen.*`: agent runs, replay frames).
    * `:aggregate` — the token-blind cross-tenant plane: every resource whose policy is
      `Samen.Policy.AggregateActorOnly` (default-deny, no `pii_` column, no org).

  ## Edges are DECLARED relationships only (issue #97 D5)

  An edge is an Ash relationship the code declares. An undeclared `*_id` scalar stays a
  plain field — the map never infers an edge from a name. A polymorphic subject anchor
  (`subject_key` + `subject_id`, ADR-041 §4.1 — Docs, Notes, Tasks, Taggings) is not an
  edge either; the table carries `anchor?: true` ("attaches to any object").

  ## Metadata only, never a row

  Like the catalog it is built from, this module reads compile-time metadata and nothing
  else. There is no row read on any path, so the map is identical for every org and holds
  no value to mask — the same "no column to leak" argument `Samen.AI.Catalog` makes.
  """

  @universal ~w(id org_id inserted_at updated_at)

  @type layer :: :app | :framework | :aggregate

  @doc """
  Build the map for the current host's registered resources (`config :samen_core,
  :ash_domains`, the registry every verifier already reads). Override with `:domains` or
  `:resources`, exactly as `Samen.AI.Catalog.schema/1`.

  Returns `%{domains: [domain], tables: %{resource => table}, edges: [edge]}`, every list
  deterministically ordered.
  """
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    modules = resources(opts)
    by_name = Map.new(modules, &{inspect(&1), &1})
    dict = Samen.AI.Catalog.dict(modules)

    tables =
      dict["tables"]
      |> Enum.map(&table(&1, Map.get(by_name, &1["resource"])))
      |> Map.new(&{&1.resource, &1})

    edges = edges(dict["tables"], tables)

    %{domains: domains(tables, edges), tables: tables, edges: edges}
  end

  @doc "The domain with `slug` from a built map, or `nil`."
  def domain(%{domains: domains}, slug), do: Enum.find(domains, &(&1.slug == slug))

  @doc "The fields every org-scoped table carries — rendered collapsed, not per table."
  def universal_fields, do: @universal

  # ---------------------------------------------------------------------------

  defp resources(opts) do
    case Keyword.get(opts, :resources) do
      list when is_list(list) ->
        list

      _ ->
        opts
        |> Keyword.get(:domains, Application.get_env(:samen_core, :ash_domains, []))
        |> Samen.Catalog.resource_modules()
    end
  end

  defp table(entry, module) do
    domain_mod = module && Ash.Resource.Info.domain(module)
    names = MapSet.new(entry["fields"], & &1["logical_name"])
    fk = Map.new(entry["relationships"] || [], &fk_pair/1)

    fields =
      Enum.map(entry["fields"], fn f ->
        %{
          name: f["logical_name"],
          column: f["column_name"],
          type: short_type(f["type"]),
          pii: f["pii"],
          universal: f["logical_name"] in @universal,
          references: Map.get(fk, f["logical_name"])
        }
      end)

    %{
      resource: entry["resource"],
      name: entry["resource"] |> String.split(".") |> List.last(),
      table_name: entry["table_name"],
      domain: slug(domain_mod, entry["resource"]),
      domain_module: domain_mod && inspect(domain_mod),
      layer: layer(module, domain_mod),
      fields: fields,
      pii_count: Enum.count(fields, & &1.pii),
      org_scoped: MapSet.member?(names, "org_id"),
      anchor: MapSet.member?(names, "subject_key") and MapSet.member?(names, "subject_id")
    }
  end

  defp fk_pair(%{"type" => "belongs_to"} = r), do: {r["source_attribute"], r["destination"]}
  defp fk_pair(r), do: {nil, r["destination"]}

  # Edges point CHILD → PARENT (the side holding the foreign key → the side it names).
  # A has_many/has_one is the same edge seen from the parent, so it is drawn only when no
  # belongs_to already declares it; a many_to_many is one edge, labelled with its join.
  defp edges(entries, tables) do
    declared =
      for e <- entries, r <- e["relationships"] || [] do
        case r["type"] do
          "belongs_to" ->
            %{
              from: e["resource"],
              to: r["destination"],
              name: r["name"],
              type: :belongs_to,
              via: r["source_attribute"],
              through: nil
            }

          type when type in ["has_many", "has_one"] ->
            %{
              from: r["destination"],
              to: e["resource"],
              name: r["name"],
              type: String.to_atom(type),
              via: r["destination_attribute"],
              through: nil
            }

          "many_to_many" ->
            %{
              from: e["resource"],
              to: r["destination"],
              name: r["name"],
              type: :many_to_many,
              via: nil,
              through: r["through"]
            }

          _ ->
            nil
        end
      end

    declared = Enum.reject(declared, &is_nil/1)
    belongs = MapSet.new(for e <- declared, e.type == :belongs_to, do: {e.from, e.to, e.via})

    declared
    |> Enum.reject(fn e ->
      e.type in [:has_many, :has_one] and MapSet.member?(belongs, {e.from, e.to, e.via})
    end)
    |> Enum.uniq_by(&{&1.from, &1.to, &1.via, &1.through, &1.type == :many_to_many})
    |> Enum.map(fn e ->
      Map.merge(e, %{
        from_domain: get_in(tables, [e.from, :domain]),
        to_domain: get_in(tables, [e.to, :domain]),
        external: not (Map.has_key?(tables, e.from) and Map.has_key?(tables, e.to))
      })
    end)
    |> Enum.sort_by(&{&1.from, &1.name, &1.to})
  end

  defp domains(tables, edges) do
    tables
    |> Map.values()
    |> Enum.group_by(& &1.domain)
    |> Enum.map(fn {slug, ts} ->
      ts = Enum.sort_by(ts, & &1.name)
      cross = Enum.filter(edges, &(&1.from_domain != &1.to_domain))

      %{
        slug: slug,
        name: display_name(slug),
        module: hd(ts).domain_module,
        layer: dominant_layer(ts),
        tables: Enum.map(ts, & &1.resource),
        table_count: length(ts),
        pii_count: Enum.sum(Enum.map(ts, & &1.pii_count)),
        links_out: count_by(for(e <- cross, e.from_domain == slug, do: e.to_domain)),
        links_in: count_by(for(e <- cross, e.to_domain == slug, do: e.from_domain))
      }
    end)
    |> Enum.sort_by(&{layer_rank(&1.layer), &1.slug})
  end

  defp count_by(list), do: list |> Enum.reject(&is_nil/1) |> Enum.frequencies() |> Enum.sort()

  defp dominant_layer(ts) do
    ts
    |> Enum.map(& &1.layer)
    |> Enum.frequencies()
    |> Enum.max_by(fn {l, n} -> {n, -layer_rank(l)} end)
    |> elem(0)
  end

  defp layer_rank(:app), do: 0
  defp layer_rank(:framework), do: 1
  defp layer_rank(:aggregate), do: 2

  defp layer(module, domain_mod) do
    cond do
      aggregate_only?(module) -> :aggregate
      domain_mod && String.starts_with?(inspect(domain_mod), "Samen.") -> :framework
      true -> :app
    end
  end

  defp aggregate_only?(nil), do: false

  defp aggregate_only?(module) do
    module
    |> Ash.Policy.Info.policies()
    |> Enum.flat_map(& &1.policies)
    |> Enum.any?(&(&1.check_module == Samen.Policy.AggregateActorOnly))
  rescue
    _ -> false
  end

  # `Driftwood.SalesOps` → "sales_ops"; `Samen.AI.Domain` → "ai" (a trailing `Domain`
  # segment names the module, not the scope).
  defp slug(nil, resource),
    do: resource |> String.split(".") |> Enum.at(-2, "other") |> Macro.underscore()

  defp slug(domain_mod, _resource) do
    domain_mod
    |> Module.split()
    |> Enum.reject(&(&1 == "Domain"))
    |> List.last()
    |> Macro.underscore()
  end

  defp display_name("ai"), do: "AI"
  defp display_name("crm"), do: "CRM"

  defp display_name(slug) do
    slug |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp short_type(type) when is_binary(type) do
    type |> String.split(".") |> List.last()
  end

  defp short_type(type), do: to_string(type)
end
