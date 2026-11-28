defmodule Samen.Scope.ApiKey.Grammar do
  @moduledoc """
  The grammar of an API key's declared scopes, checked when a key is created.

  A scope map is non-empty. Each key is `"all"`, a family (`"crm"`) or `"<family>.<type>"` (`"crm.contact"`), as an
  atom or a string; a family and a type are lowercase names of letters, digits and underscores, so a family never
  contains a dot. Each value is a non-empty list of `"read"` and/or `"write"` (atoms or strings).

  `validate/1` is the grammar alone, which the `ApiKey` resource's own `:create` enforces (the resource cannot know a
  host's families). `validate_membership/2` also checks that each family, and each type of a `family.type`, exists in a
  host's `catalogue/1` (the families and JSON:API types of its resources); the settings mint wrapper does that.
  """

  @name ~r/\A[a-z][a-z0-9_]*\z/
  @classes ["read", "write"]

  @doc "`:ok`, or `{:error, reason}` (a sentence naming the first thing outside the grammar)."
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(scopes) when scopes == %{}, do: {:error, "a key needs at least one scope: an empty scope map authorizes nothing"}

  def validate(scopes) when is_map(scopes) do
    Enum.find_value(scopes, :ok, fn {key, actions} ->
      case check(key, actions) do
        :ok -> nil
        {:error, _} = error -> error
      end
    end)
  end

  def validate(_scopes), do: {:error, "scopes must be a map of scope to [read | write]"}

  defp check(key, actions) do
    with :ok <- check_key(key), do: check_actions(key, actions)
  end

  defp check_key(key) when is_atom(key) or is_binary(key) do
    case key |> to_string() |> String.split(".") do
      ["all"] -> :ok
      [family] -> name_ok(key, family)
      [family, type] -> with :ok <- name_ok(key, family), do: name_ok(key, type)
      _ -> {:error, "scope #{inspect(key)} is not `all`, a family or `family.type`"}
    end
  end

  defp check_key(key), do: {:error, "scope #{inspect(key)} is not `all`, a family or `family.type`"}

  defp name_ok(key, name) do
    if Regex.match?(@name, name),
      do: :ok,
      else: {:error, "scope #{inspect(key)} is not `all`, a family or `family.type` (lowercase letters, digits and underscores)"}
  end

  defp check_actions(key, actions) when is_list(actions) and actions != [] do
    if Enum.all?(actions, &(action_string(&1) in @classes)),
      do: :ok,
      else: {:error, "scope #{inspect(key)} must list only read and write"}
  end

  defp check_actions(key, _actions), do: {:error, "scope #{inspect(key)} must list read and/or write"}

  defp action_string(a) when is_atom(a) or is_binary(a), do: to_string(a)
  defp action_string(_), do: nil

  @doc """
  `%{family => [type]}` for the resources of `domains` that are exposed over JSON:API (a resource with a JSON:API
  type), keyed by `Samen.Scope.ApiKey.family/1`.
  """
  @spec catalogue([module()]) :: %{String.t() => [String.t()]}
  def catalogue(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.flat_map(fn resource ->
      case Samen.Scope.ApiKey.json_api_type(resource) do
        nil -> []
        type -> [{Samen.Scope.ApiKey.family(resource), type}]
      end
    end)
    |> Enum.reject(fn {family, _type} -> is_nil(family) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {family, types} -> {family, types |> Enum.uniq() |> Enum.sort()} end)
  end

  @doc "`:ok` when every family and `family.type` of `scopes` is in `catalogue` (`all` always is); else `{:error, reason}`."
  @spec validate_membership(map(), %{String.t() => [String.t()]}) :: :ok | {:error, String.t()}
  def validate_membership(scopes, catalogue) when is_map(scopes) do
    Enum.find_value(scopes, :ok, fn {key, _actions} ->
      case to_string(key) |> String.split(".") do
        ["all"] ->
          nil

        [family] ->
          if Map.has_key?(catalogue, family), do: nil, else: {:error, "scope #{inspect(key)} names a family this app does not expose"}

        [family, type] ->
          if type in Map.get(catalogue, family, []),
            do: nil,
            else: {:error, "scope #{inspect(key)} names a family or type this app does not expose"}

        _ ->
          {:error, "scope #{inspect(key)} is not `all`, a family or `family.type`"}
      end
    end)
  end
end

defmodule Samen.Scope.ApiKey.ValidScopes do
  @moduledoc """
  Resource validation: a key is created only with scopes inside `Samen.Scope.ApiKey.Grammar` and at least one of them.
  It runs on the resource's own `:create`, so it holds for every write path, not just the settings mint.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Samen.Scope.ApiKey.Grammar.validate(Ash.Changeset.get_attribute(changeset, :scopes)) do
      :ok -> :ok
      {:error, reason} -> {:error, field: :scopes, message: reason}
    end
  end
end
