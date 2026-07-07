defmodule Samen.ApiContract do
  @moduledoc """
  Core logic for the `samen.verify.api_contract` verifier (C6, plan §C6).

  Snapshots the v1 contract (routes, fields, types, required args) into a
  deterministic JSON artifact and diffs current vs snapshot to detect un-versioned
  STRUCTURAL breaks:

  - Removed field (`field_removed`)
  - Renamed field — detected as a remove + add, reported as `field_removed`
  - Narrowed type (`type_narrowed`) — a type change that is not an identity is
    treated as a narrowing (same-type widening is additive; type changes are
    structurally breaking in JSON:API consumers because they must re-parse)
  - Dropped route (`route_dropped`)
  - New required argument (`required_arg_added`)

  Additive changes are NOT violations:
  - New field added to a resource
  - New route added for a resource
  - New resource added
  - New optional argument added

  Semantic breaks (same shape, changed meaning or unit) are explicitly OUT OF SCOPE.
  Each diagnostic states: "NOTE: semantic breaks (changed meaning or unit with the
  same type/shape) are not caught by this structural diff — they remain the author's
  responsibility."

  ## Snapshot format

  `api_contract.v1.json` — deterministic, sorted:

  ```json
  {
    "version": "v1",
    "resources": [
      {
        "type": "contact",
        "module": "Elixir.Demo.Crm.Contact",
        "routes": [
          {"method": "GET", "path": "/contacts/:id", "action": "read", "required_args": []}
        ],
        "fields": [
          {"name": "display_name", "type": "Ash.Type.String", "required": false}
        ]
      }
    ]
  }
  ```

  Keys are sorted alphabetically at every level. Resources are sorted by `type`.
  Routes are sorted by `method` then `path`. Fields are sorted by `name`.

  ## Anti-tautology note

  The verifier FAILS (exit 1) when a structural break is present in the LIVE contract
  vs the snapshot. An always-pass implementation would be a tautology — the
  anti-tautology probe confirms the verifier actually catches each of the four break
  classes (tested by seeding violations in a scratch copy of the snapshot, calling
  `diff/2`, and asserting violations are returned).
  """

  alias Samen.ApiContract.Snapshot
  alias Samen.ApiContract.Differ

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Snapshot the live API contract for the given domains.

  Returns a map ready for JSON serialization. The map is deterministically ordered
  (resources sorted by type, routes sorted by method+path, fields sorted by name).
  """
  def snapshot(domains, version \\ "v1") when is_list(domains) do
    Snapshot.build(domains, version)
  end

  @doc """
  Diff a live snapshot against a stored snapshot.

  Returns `{:ok, []}` if no structural breaks were found (additive-only changes
  are allowed).

  Returns `{:error, violations}` where violations is a non-empty list of
  human-readable strings describing each structural break.
  """
  def diff(live, stored) do
    Differ.diff(live, stored)
  end

  @doc """
  Encode a snapshot to indented JSON with deterministic key ordering.
  """
  def encode!(snapshot) do
    snapshot
    |> sort_deeply()
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Decode a stored snapshot JSON string.
  """
  def decode!(json) do
    Jason.decode!(json)
  end

  # ---------------------------------------------------------------------------
  # Deterministic key ordering
  # ---------------------------------------------------------------------------

  @doc false
  def sort_deeply(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new(fn {k, v} -> {k, sort_deeply(v)} end)
  end

  def sort_deeply(list) when is_list(list), do: Enum.map(list, &sort_deeply/1)
  def sort_deeply(other), do: other
end

defmodule Samen.ApiContract.Snapshot do
  @moduledoc false

  @doc """
  Build a deterministic snapshot map from a list of Ash domains.

  Requires `AshJsonApi` to be available (the caller is responsible for checking
  this before calling). Resources in the domains that have no `json_api type`
  (i.e. not AshJsonApi-exposed) are silently skipped.
  """
  def build(domains, version) when is_list(domains) do
    resources =
      domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.flat_map(&resource_entry/1)
      |> Enum.sort_by(& &1["type"])

    %{
      "version" => version,
      "resources" => resources
    }
  end

  defp resource_entry(resource) do
    try do
      # Use apply/3 to avoid compile-time warnings in samen_core where
      # AshJsonApi is an optional dep (only the host app — e.g. demo — has it).
      info_mod = Module.concat(["AshJsonApi", "Resource", "Info"])
      type = apply(info_mod, :type, [resource])

      if is_nil(type) or type == "" do
        []
      else
        fields = build_fields(resource)
        routes = build_routes(resource)

        entry = %{
          "fields" => fields,
          "module" => inspect(resource),
          "routes" => routes,
          "type" => type
        }

        [entry]
      end
    rescue
      # If AshJsonApi.Resource.Info is not available or the resource isn't
      # an AshJsonApi resource, skip silently.
      _ -> []
    end
  end

  defp build_fields(resource) do
    info_mod = Module.concat(["AshJsonApi", "Resource", "Info"])

    show_fields =
      try do
        apply(info_mod, :show_fields, [resource]) || []
      rescue
        _ -> []
      end

    show_fields_set = MapSet.new(show_fields)

    all_attrs = Ash.Resource.Info.attributes(resource)

    all_attrs
    |> Enum.filter(fn attr -> MapSet.member?(show_fields_set, attr.name) end)
    |> Enum.sort_by(fn attr -> to_string(attr.name) end)
    |> Enum.map(fn attr ->
      %{
        "name" => to_string(attr.name),
        "required" => !attr.allow_nil?,
        "type" => type_string(attr.type)
      }
    end)
  end

  defp build_routes(resource) do
    info_mod = Module.concat(["AshJsonApi", "Resource", "Info"])

    routes =
      try do
        apply(info_mod, :routes, [resource]) || []
      rescue
        _ -> []
      end

    routes
    |> Enum.sort_by(fn r -> {r.method, r.route} end)
    |> Enum.map(fn r ->
      required_args = build_required_args(resource, r.action)

      %{
        "action" => to_string(r.action),
        "method" => normalize_method(r.method),
        "path" => r.route,
        "required_args" => required_args
      }
    end)
  end

  defp build_required_args(resource, action_name) do
    action = Ash.Resource.Info.action(resource, action_name)

    if is_nil(action) do
      []
    else
      action
      |> Map.get(:arguments, [])
      |> Enum.filter(fn arg -> !arg.allow_nil? end)
      |> Enum.sort_by(fn arg -> to_string(arg.name) end)
      |> Enum.map(fn arg -> to_string(arg.name) end)
    end
  end

  defp type_string(type) do
    type
    |> inspect()
    |> String.trim_leading("Elixir.")
  end

  defp normalize_method(method) when is_atom(method), do: method |> to_string() |> String.upcase()
  defp normalize_method(method) when is_binary(method), do: String.upcase(method)
end

defmodule Samen.ApiContract.Differ do
  @moduledoc false

  @semantic_break_note "NOTE: semantic breaks (changed meaning or unit with the same type/shape) are not caught by this structural diff — they remain the author's responsibility."

  @doc """
  Compare live vs stored snapshot maps. Returns `{:ok, []}` if clean,
  `{:error, violations}` if structural breaks found.

  Additive changes (new resource, new field, new route, new optional arg) PASS.
  """
  def diff(live, stored) do
    stored_resources = index_by(stored["resources"] || [], "type")
    live_resources = index_by(live["resources"] || [], "type")

    violations =
      Enum.flat_map(stored_resources, fn {type, stored_resource} ->
        case Map.get(live_resources, type) do
          nil ->
            ["route_dropped: resource type \"#{type}\" (#{stored_resource["module"]}) no longer exists in the API — #{@semantic_break_note}"]

          live_resource ->
            field_violations(type, live_resource, stored_resource) ++
              route_violations(type, live_resource, stored_resource) ++
              required_arg_violations(type, live_resource, stored_resource)
        end
      end)

    if violations == [] do
      {:ok, []}
    else
      {:error, violations}
    end
  end

  # --- Field checks ---------------------------------------------------------

  defp field_violations(type, live_resource, stored_resource) do
    stored_fields = index_by(stored_resource["fields"] || [], "name")
    live_fields = index_by(live_resource["fields"] || [], "name")

    Enum.flat_map(stored_fields, fn {field_name, stored_field} ->
      case Map.get(live_fields, field_name) do
        nil ->
          [
            "field_removed: #{type}.#{field_name} was in the v1 contract but is no longer exposed — #{@semantic_break_note}"
          ]

        live_field ->
          type_check(type, field_name, live_field, stored_field)
      end
    end)
  end

  defp type_check(type, field_name, live_field, stored_field) do
    if live_field["type"] != stored_field["type"] do
      [
        "type_narrowed: #{type}.#{field_name} changed type from \"#{stored_field["type"]}\" to \"#{live_field["type"]}\" — #{@semantic_break_note}"
      ]
    else
      []
    end
  end

  # --- Route checks ---------------------------------------------------------

  defp route_violations(type, live_resource, stored_resource) do
    stored_routes = index_routes(stored_resource["routes"] || [])
    live_routes = index_routes(live_resource["routes"] || [])

    Enum.flat_map(stored_routes, fn {route_key, _stored_route} ->
      {method, path} = route_key

      case Map.get(live_routes, route_key) do
        nil ->
          ["route_dropped: #{type} #{method} #{path} was in the v1 contract but is no longer present — #{@semantic_break_note}"]

        _live_route ->
          []
      end
    end)
  end

  defp index_routes(routes) do
    Map.new(routes, fn r -> {{r["method"], r["path"]}, r} end)
  end

  # --- Required arg checks --------------------------------------------------

  defp required_arg_violations(type, live_resource, stored_resource) do
    stored_routes = index_routes(stored_resource["routes"] || [])
    live_routes = index_routes(live_resource["routes"] || [])

    Enum.flat_map(stored_routes, fn {{method, path} = route_key, stored_route} ->
      case Map.get(live_routes, route_key) do
        nil ->
          # Already caught by route_violations
          []

        live_route ->
          stored_args = MapSet.new(stored_route["required_args"] || [])
          live_args = MapSet.new(live_route["required_args"] || [])

          new_required =
            MapSet.difference(live_args, stored_args) |> MapSet.to_list() |> Enum.sort()

          Enum.map(new_required, fn arg ->
            "required_arg_added: #{type} #{method} #{path} gained a new required argument \"#{arg}\" — #{@semantic_break_note}"
          end)
      end
    end)
  end

  # --- Helpers --------------------------------------------------------------

  defp index_by(list, key) when is_list(list) do
    Map.new(list, fn item -> {item[key], item} end)
  end
end
