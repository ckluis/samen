defmodule Samen.Api.Help do
  @moduledoc """
  What THIS caller can do over the JSON:API, described for the caller itself (`GET /api/help`, ADR-029 amendment).

  The description is derived, never hand-kept: for each JSON:API route of each resource the router serves it asks
  Ash the question the request itself would meet, `Ash.can({resource, action}, actor, …)`, so the resource's own
  policies, the framework's API-key scope policy (`Samen.Policy.ApiKeyScope`, always the first policy of a resource
  exposed over JSON:API) and the key's role all answer. An action Ash does not allow is not listed; a resource with
  no allowed action is not listed; a relation is listed only when both ends are listed. An update or destroy route
  also needs the read that loads its record, and a route that names a relationship also needs the read of its
  destination.

  "Listed" means Ash answered `true` or `:maybe` to every question the route meets, with no query run. `:maybe` is an
  action that the policies allow for some records only (a filter or a row-dependent policy decides, which needs rows
  the description never reads): it is listed with `"conditional": true`. A policy that Ash cannot decide without data
  (`access_type :strict` over a filter) is refused by Ash and is not listed.

    * `index/3` and `resource/4` are pure over `(actor, router)`: no tenant row is read (`run_queries?: false`), so no
      tenant data and no PII value can reach the description. Each action entry carries `scope` (the narrowest key
      grant that permits it, in the key grammar of `Samen.Scope.ApiKey`) and `also_granted_by` (the wider scope names). A PII field appears by name, type, and `pii: true`;
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

  @typedoc "One allowed route: the route as AshJsonApi declares it, its Ash action, its class, whether it is conditional, and the `{resource, classes}` its key must cover."
  @type allowed :: %{route: map(), action: map(), class: :read | :write, conditional: boolean(), parts: [{module(), [:read | :write]}]}

  @doc "The scope family of a resource (`Samen.Scope.ApiKey.family/1`): the one name a key's scope uses for it."
  @spec family(module()) :: String.t() | nil
  def family(resource), do: ApiKey.family(resource)

  @doc "The JSON:API types the caller may use at least one action of, as a `MapSet`."
  @spec visible_types(term(), module()) :: MapSet.t(String.t())
  def visible_types(actor, router) do
    actor |> survey(router) |> MapSet.new(& &1.type)
  end

  @doc "May the caller use at least one action of `type`? Asks about that one resource only; no other type is evaluated."
  @spec visible?(term(), module(), String.t()) :: boolean()
  def visible?(actor, router, type) when is_binary(type), do: survey(actor, router, type) != []

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

  defp survey(actor, router, only_type \\ nil) do
    for domain <- router.domains(),
        resource <- Ash.Domain.Info.resources(domain),
        type = ApiKey.json_api_type(resource),
        type != nil,
        only_type == nil or type == only_type,
        allowed = allowed_routes(actor, resource, domain),
        allowed != [] do
      %{resource: resource, domain: domain, type: type, allowed: allowed}
    end
    |> Enum.uniq_by(& &1.type)
    |> Enum.sort_by(& &1.type)
  end

  # Each (resource, action) is asked once per description, however many routes name it.
  defp allowed_routes(actor, resource, domain) do
    {allowed, _memo} =
      Enum.reduce(routes(resource), {[], %{}}, fn route, {acc, memo} ->
        case route_answer(actor, resource, domain, route, memo) do
          {:no, memo} -> {acc, memo}
          {answer, action, parts, memo} -> {[entry(route, action, answer, parts) | acc], memo}
        end
      end)

    Enum.sort_by(allowed, &{&1.route.route, to_string(&1.route.method), to_string(&1.action.name)})
  end

  defp entry(route, action, answer, parts) do
    %{route: route, action: action, class: ApiKey.action_class(action.type), conditional: answer == :maybe, parts: parts}
  end

  defp route_answer(actor, resource, domain, route, memo) do
    with true <- is_atom(route.action) and route.action != nil,
         %{} = action <- Ash.Resource.Info.action(resource, route.action),
         {:ok, answer, parts, memo} <- ask_route(actor, resource, domain, route, action, memo) do
      {answer, action, parts, memo}
    else
      {:no, memo} -> {:no, memo}
      _ -> {:no, memo}
    end
  end

  # The route's own action, the read that loads the record of an update or destroy (the request reads the row first),
  # and, for a relationship route, the read of the destination: a route is listed only when EVERY question it meets is
  # allowed. `parts` is what the key's scopes must cover: `{resource, [class]}` per resource asked about.
  defp ask_route(actor, resource, domain, route, action, memo) do
    {own, memo} = ask(memo, actor, resource, action, domain)
    own_part = {resource, [ApiKey.action_class(action.type)]}

    with true <- own != :no,
         {:ok, load, load_parts, memo} <- load_question(actor, resource, domain, route, action, memo),
         {:ok, dest, dest_parts, memo} <- destination_question(actor, resource, route, memo) do
      answer = Enum.reduce([own, load, dest], :yes, &combine/2)
      {:ok, answer, [own_part | load_parts] ++ dest_parts, memo}
    else
      {:no, memo} -> {:no, memo}
      _ -> {:no, memo}
    end
  end

  defp load_question(actor, resource, domain, route, %{type: type}, memo) when type in [:update, :destroy] do
    read =
      case Map.get(route, :read_action) do
        nil -> Ash.Resource.Info.primary_action(resource, :read)
        name -> Ash.Resource.Info.action(resource, name)
      end

    with %{} <- read,
         {answer, memo} when answer != :no <- ask(memo, actor, resource, read, domain) do
      {:ok, answer, [{resource, [:read]}], memo}
    else
      {:no, memo} -> {:no, memo}
      _ -> {:no, memo}
    end
  end

  defp load_question(_actor, _resource, _domain, _route, _action, memo), do: {:ok, :yes, [], memo}

  # A route that names a relationship reaches the destination resource: the destination must be served over the
  # JSON:API (it has a type) and the caller must be allowed to read it, else the route is not listed.
  defp destination_question(actor, resource, route, memo) do
    case Map.get(route, :relationship) do
      nil ->
        {:ok, :yes, [], memo}

      name ->
        with %{destination: dest} = rel <- Ash.Resource.Info.public_relationship(resource, name),
             true <- ApiKey.json_api_type(dest) != nil,
             %{} = read <- relationship_read(rel, dest),
             {answer, memo} when answer != :no <- ask(memo, actor, dest, read, Ash.Resource.Info.domain(dest)) do
          {:ok, answer, [{dest, [:read]}], memo}
        else
          {:no, memo} -> {:no, memo}
          _ -> {:no, memo}
        end
    end
  end

  defp relationship_read(%{read_action: nil}, dest), do: Ash.Resource.Info.primary_action(dest, :read)
  defp relationship_read(%{read_action: name}, dest), do: Ash.Resource.Info.action(dest, name)

  defp combine(:no, _), do: :no
  defp combine(_, :no), do: :no
  defp combine(:maybe, _), do: :maybe
  defp combine(_, :maybe), do: :maybe
  defp combine(:yes, :yes), do: :yes

  defp routes(resource), do: apply(@json_api_info, :routes, [resource]) || []

  defp ask(memo, actor, resource, action, domain) do
    key = {resource, action.name}

    case memo do
      %{^key => answer} -> {answer, memo}
      _ -> answer = can(actor, resource, action, domain); {answer, Map.put(memo, key, answer)}
    end
  end

  # `:yes` (nothing narrows which records the action applies to), `:maybe` (the policies allow it for some records
  # only: a filter or a row-dependent policy decides), `:no` (refused, or Ash could not answer: the description
  # under-reports, never over-reports). Ash answers a read with `maybe_is: :maybe` whenever a filter is attached
  # without running it, so for a read the filter itself (`alter_source?`) says whether anything narrows the rows.
  defp can(actor, resource, action, _domain) do
    opts = [maybe_is: :maybe, run_queries?: false, alter_source?: action.type == :read]

    case Ash.can({resource, action}, actor, opts) do
      {:ok, true} -> :yes
      {:ok, true, %Ash.Query{filter: nil}} -> :yes
      {:ok, true, %Ash.Query{}} -> :maybe
      {:ok, :maybe} -> :maybe
      {:error, error} -> report_can(error)
      _ -> :no
    end
  rescue
    e -> report_can(e)
  catch
    kind, reason -> report_can({kind, reason})
  end

  defp report_can(reason) do
    Failure.report(:api_help_can, nil, reason)
    :no
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

  defp action_entry(%{route: route, action: action, class: class, conditional: conditional, parts: parts}, _resource, prefix) do
    grant = grant(parts)

    %{
      "name" => to_string(action.name),
      "class" => to_string(class),
      "route" => to_string(route.type),
      "method" => route.method |> to_string() |> String.upcase(),
      "path" => prefix <> route.route,
      "scope" => grant.scope,
      "also_granted_by" => grant.also_granted_by,
      "conditional" => conditional,
      "required_args" =>
        action.arguments
        |> Enum.filter(&(!&1.allow_nil?))
        |> Enum.map(&to_string(&1.name))
        |> Enum.sort()
    }
  end

  # The scope a key must carry for the whole route, in the key grammar (`Samen.Scope.ApiKey.grant_for/3`): the
  # narrowest name per resource the route meets, with the classes it needs, and the wider names that also grant it.
  defp grant(parts) do
    grants =
      for {resource, classes} <- Enum.uniq(parts) do
        ApiKey.grant_for(family(resource), ApiKey.json_api_type(resource), classes)
      end

    scope =
      Enum.reduce(grants, %{}, fn %{scope: scope}, acc ->
        Map.merge(acc, scope, fn _name, a, b -> Enum.sort(Enum.uniq(a ++ b)) end)
      end)

    also =
      grants
      |> Enum.map(&MapSet.new(&1.also_granted_by))
      |> Enum.reduce(&MapSet.intersection/2)
      |> MapSet.to_list()
      |> Enum.sort_by(&(&1 == "all"))

    %{scope: scope, also_granted_by: also}
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
  # attributes minus `hide_fields`) let through, and only ever a public attribute, whatever `show_fields` names.
  defp shown_attributes(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.filter(&apply(@json_api_info, :show_field?, [resource, &1.name]))
    |> Enum.filter(& &1.public?)
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
