defmodule Samen.ApiKeyScopeGuard do
  @moduledoc """
  The walk behind the host guard tests for API-key scope enforcement. A host test calls `report/1` with its
  `:ash_domains` (and, for the family check, its JSON:API router) and asserts the result:

    * `:exposed` are the resources that declare a JSON:API type;
    * `:unguarded` are exposed resources whose FIRST policy is not `Samen.Policy.ApiKeyScope` (`Samen.Transformers.ApiKeyScopePolicy`
      puts it there; a resource without it would serve a key's request on its role alone);
    * `:walked` counts every resource visited, so a test can prove the walk saw the host (never vacuous);
    * `families/1` maps a router's domains to their scope families, and `duplicate_families/1` lists a family two of
      them share (a scope on it would then cover both).

  A host with no JSON:API (no `ash_json_api` dependency) reports `exposed: []`.
  """

  alias Samen.Scope.ApiKey

  @type report :: %{walked: non_neg_integer(), exposed: [module()], unguarded: [module()]}

  @doc "Walk every resource of `domains`."
  @spec report([module()]) :: report()
  def report(domains) do
    resources = Enum.flat_map(domains, &Ash.Domain.Info.resources/1)
    exposed = Enum.filter(resources, &(ApiKey.json_api_type(&1) != nil))

    %{walked: length(resources), exposed: exposed, unguarded: Enum.reject(exposed, &guarded?/1)}
  end

  @doc "Is the resource's first policy the API-key scope policy?"
  @spec guarded?(module()) :: boolean()
  def guarded?(resource) do
    case Ash.Policy.Info.policies(resource) do
      [%{policies: [%{type: :forbid_unless, check: {Samen.Policy.ApiKeyScope, _}} | _]} | _] -> true
      _ -> false
    end
  end

  @doc "`%{family => [domain]}` for the JSON:API domains of `router` (a module exposing `domains/0`)."
  @spec families(module()) :: %{String.t() => [module()]}
  def families(router) do
    router.domains()
    |> Enum.group_by(&domain_family/1)
  end

  @doc "Families shared by more than one domain of `router`."
  @spec duplicate_families(module()) :: [String.t()]
  def duplicate_families(router) do
    for {family, [_, _ | _]} <- families(router), do: family
  end

  defp domain_family(domain) do
    if Code.ensure_loaded?(domain) and function_exported?(domain, :samen_api_family, 0),
      do: to_string(domain.samen_api_family()),
      else: domain |> Module.split() |> List.last() |> Macro.underscore()
  end
end
