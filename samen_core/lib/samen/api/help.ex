defmodule Samen.Api.Help do
  @moduledoc """
  What THIS caller can do over the JSON:API, described for the caller itself (`GET /api/help`, ADR-029 amendment).

  The description is derived, never hand-kept: for each JSON:API route of each resource the router serves it asks
  Ash the question the request itself would meet, `Ash.can?({resource, action}, actor, …)`, so the resource's own
  policies, the framework's API-key scope policy (`Samen.Policy.ApiKeyScope`, always the first policy of a resource
  exposed over JSON:API) and the key's role all answer. An action Ash does not allow is not listed; a resource with
  no allowed action is not listed; a relation is listed only when both ends are listed.

    * `index/3` and `resource/4` are pure over `(actor, router)`: no row is read (`run_queries?: false`), so no
      tenant data and no PII value can reach the description. A PII field appears by name, type, and `pii: true`;
      `delivery` says whether a request would carry it (`"clear"`) or omit it without a reveal grant
      (`"omitted_without_grant"`, `Samen.Scope.ApiKey.masking_for/2`).
    * A question that raises is reported (`Samen.Observability.Failure`, value-free) and answers "not allowed":
      the description under-reports, never over-reports.
    * `resource/4` answers `:not_found` identically for an unknown type and for a type the caller may not use.

  Options (`opts`): `:prefix` is where the router is mounted (default `"/api/v1"`), `:help` is where help is mounted
  (default `"/api/help"`); both only shape the links.
  """

  alias Samen.Catalog.Meaning
  alias Samen.Observability.Failure
  alias Samen.Scope.ApiKey

  @default_prefix "/api/v1"
  @default_help "/api/help"
  @json_api_info Module.concat(["AshJsonApi", "Resource", "Info"])
  @write_types [:create, :update, :destroy, :action]

  @typedoc "One allowed route: the route as AshJsonApi declares it, its Ash action and the scope class it needs."
  @type allowed :: %{route: map(), action: map(), class: :read | :write}

  @doc "The scope family of a resource (`Samen.Scope.ApiKey.family/1`): the one name a key's scope uses for it."
  @spec family(module()) :: String.t() | nil
  def family(resource), do: ApiKey.family(resource)

  @doc "The JSON:API types the caller may use at least one action of, as a `MapSet`."
  @spec visible_types(term(), module()) :: MapSet.t(String.t())
  def visible_types(actor, router) do
    actor |> survey(router) |> MapSet.new(& &1.type)
  end

  @doc """
  The index: who the caller is and every resource it may use, with the actions it may run.

  An actor with no `:plane` and no `:role` still gets a map (its `caller` fields are `nil`); what it may do is
  whatever Ash allows it.
  """
  @spec index(term(), module(), keyword()) :: map()
  def index(actor, router, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, @default_prefix)
    help = Keyword.get(opts, :help, @default_help)

    resources =
      for entry <- survey(actor, router) do
        meaning = Meaning.table(entry.resource)

        %{
          "type" => entry.type,
          "label" => meaning.label,
          "description" => meaning.description,
          "synonyms" => meaning.synonyms,
          "family" => family(entry.resource),
          "actions" => entry.allowed |> Enum.map(&to_string(&1.action.name)) |> Enum.uniq() |> Enum.sort(),
          "links" => %{"help" => "#{help}/#{entry.type}"}
        }
      end

    %{
      "help_version" => "1",
      "api" => %{"base" => prefix, "media_type" => "application/vnd.api+json"},
      "caller" => caller(actor),
      "resources" => resources
    }
  end

  @doc "The detail of one type, or `:not_found` for a type that is unknown OR that the caller may not use at all."
  @spec resource(term(), module(), String.t(), keyword()) :: {:ok, map()} | :not_found
  def resource(actor, router, type, opts \\ []) when is_binary(type) do
    prefix = Keyword.get(opts, :prefix, @default_prefix)
    help = Keyword.get(opts, :help, @default_help)
    entries = survey(actor, router)

    case Enum.find(entries, &(&1.type == type)) do
      nil -> :not_found
      entry -> {:ok, detail(entry, actor, MapSet.new(entries, & &1.type), prefix, help)}
    end
  end

  # --- the survey: one question per route, asked of Ash ---------------------------------------------------------

  defp survey(actor, router) do
    for domain <- router.domains(),
        resource <- Ash.Domain.Info.resources(domain),
        type = ApiKey.json_api_type(resource),
        type != nil,
        allowed = allowed_routes(actor, resource, domain),
        allowed != [] do
      %{resource: resource, domain: domain, type: type, allowed: allowed}
    end
    |> Enum.uniq_by(& &1.type)
    |> Enum.sort_by(& &1.type)
  end

  defp allowed_routes(actor, resource, domain) do
    for route <- routes(resource),
        is_atom(route.action) and route.action != nil,
        action = Ash.Resource.Info.action(resource, route.action),
        action != nil,
        can?(actor, resource, action, domain),
        loadable?(actor, resource, route, action, domain) do
      %{route: route, action: action, class: ApiKey.action_class(action.type)}
    end
    |> Enum.sort_by(&{&1.route.route, to_string(&1.route.method), to_string(&1.action.name)})
  end

  # An update or destroy route first reads the record through its read action, so a caller who cannot run that
  # read is refused before the write: listing the write would over-report.
  defp loadable?(actor, resource, route, %{type: type}, domain) when type in [:update, :destroy] do
    read =
      case Map.get(route, :read_action) do
        nil -> Ash.Resource.Info.primary_action(resource, :read)
        name -> Ash.Resource.Info.action(resource, name)
      end

    read != nil and can?(actor, resource, read, domain)
  end

  defp loadable?(_actor, _resource, _route, _action, _domain), do: true

  defp routes(resource), do: apply(@json_api_info, :routes, [resource]) || []

  defp can?(actor, resource, action, domain) do
    Ash.can?({resource, action}, actor, domain: domain, maybe_is: true, run_queries?: false) == true
  rescue
    e ->
      Failure.report(:api_help_can, nil, e)
      false
  catch
    kind, reason ->
      Failure.report(:api_help_can, nil, {kind, reason})
      false
  end

  # --- the caller ----------------------------------------------------------------------------------------------

  defp caller(actor) do
    %{"plane" => name(field(actor, :plane)), "role" => name(field(actor, :role))}
    |> put_scopes(field(actor, :api_key))
  end

  defp put_scopes(caller, %{} = key), do: Map.put(caller, "scopes", scopes(Map.get(key, :scopes)))
  defp put_scopes(caller, _no_key), do: caller

  defp scopes(%{} = scopes) do
    for {key, actions} <- scopes, is_list(actions), into: %{} do
      {to_string(key), actions |> Enum.filter(&(is_atom(&1) or is_binary(&1))) |> Enum.map(&to_string/1) |> Enum.sort()}
    end
  end

  defp scopes(_), do: %{}

  defp field(%{} = map, key), do: Map.get(map, key)
  defp field(_other, _key), do: nil

  defp name(nil), do: nil
  defp name(value), do: to_string(value)

  # --- one resource --------------------------------------------------------------------------------------------

  defp detail(entry, actor, visible, prefix, help) do
    resource = entry.resource
    meaning = Meaning.table(resource)
    type = entry.type

    %{
      "type" => type,
      "label" => meaning.label,
      "description" => meaning.description,
      "synonyms" => meaning.synonyms,
      "family" => family(resource),
      "fields" => fields(resource, actor, entry.allowed),
      "actions" => Enum.map(entry.allowed, &action_entry(&1, resource, prefix)),
      "relations" => relations(resource, visible),
      "links" => %{"self" => "#{help}/#{type}", "index" => help}
    }
  end

  defp action_entry(%{route: route, action: action, class: class}, resource, prefix) do
    %{
      "name" => to_string(action.name),
      "class" => to_string(class),
      "route" => to_string(route.type),
      "method" => route.method |> to_string() |> String.upcase(),
      "path" => prefix <> route.route,
      "scope" => "#{family(resource)}:#{class}",
      "required_args" =>
        action.arguments
        |> Enum.filter(&(!&1.allow_nil?))
        |> Enum.map(&to_string(&1.name))
        |> Enum.sort()
    }
  end

  defp fields(resource, actor, allowed) do
    shown = shown_attributes(resource)
    meanings = Meaning.fields(resource)
    writable = writable_names(allowed)
    delivery = delivery(actor)

    for attr <- shown do
      name = to_string(attr.name)
      pii? = Samen.Pii.Info.vault_routed?(resource, attr.name)
      m = Map.fetch!(meanings, name)

      %{
        "name" => name,
        "label" => m.label,
        "description" => m.description,
        "synonyms" => m.synonyms,
        "type" => attr.type |> inspect() |> String.trim_leading("Elixir."),
        "required" => !attr.allow_nil? and is_nil(attr.default),
        "read_only" => not MapSet.member?(writable, attr.name),
        "pii" => pii?,
        "delivery" => if(pii?, do: delivery, else: "clear")
      }
      |> put_present("units", m.units)
      |> put_present("allowed_values", m.allowed_values)
      |> put_present("max_length", m.max_length)
    end
  end

  # The attributes the serializer emits: those the resource's `show_fields` (or, with none declared, its public
  # attributes minus `hide_fields`) let through. Never a field the API would omit.
  defp shown_attributes(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(&apply(@json_api_info, :show_field?, [resource, &1.name]))
    |> Enum.filter(fn attr -> apply(@json_api_info, :show_fields, [resource]) != nil or attr.public? end)
    |> Enum.sort_by(&to_string(&1.name))
  end

  defp writable_names(allowed) do
    for %{action: %{type: type} = action} <- allowed, type in @write_types, reduce: MapSet.new() do
      acc ->
        names = Map.get(action, :accept, []) ++ Enum.map(Map.get(action, :arguments, []), & &1.name)
        Enum.into(names, acc)
    end
  end

  # A tenant caller over its own org reads PII in clear; an operator-plane caller gets a vaulted field only with a
  # reveal grant, which the description cannot know (it reads no row), so it says the field is omitted without one.
  defp delivery(actor) do
    key = field(actor, :api_key)

    plane = field(actor, :plane) || field(key, :plane)
    org_id = field(actor, :org_id) || field(key, :org_id)

    # No org to be "own" of, or a plane that is not the tenant's: the field is not promised.
    with true <- is_binary(org_id),
         :clear <- ApiKey.masking_for(%{org_id: org_id, plane: plane, scopes: %{}, minter_role: nil, expires_at: nil}, org_id) do
      "clear"
    else
      _ -> "omitted_without_grant"
    end
  end

  # A relation is described only when its source attribute is served and its destination is a resource the caller
  # may use: the description never names a type the caller cannot reach.
  defp relations(resource, visible) do
    served = resource |> shown_attributes() |> MapSet.new(& &1.name)

    for rel <- Ash.Resource.Info.public_relationships(resource),
        MapSet.member?(served, rel.source_attribute),
        target = ApiKey.json_api_type(rel.destination),
        target != nil and MapSet.member?(visible, target) do
      %{
        "name" => to_string(rel.name),
        "kind" => to_string(rel.type),
        "field" => to_string(rel.source_attribute),
        "target" => target
      }
    end
    |> Enum.sort_by(& &1["name"])
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, []), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
