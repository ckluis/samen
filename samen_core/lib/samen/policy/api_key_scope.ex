defmodule Samen.Policy.ApiKeyScope do
  @moduledoc """
  The API-key scope check: a request made with an API key is allowed only when the key's declared scopes
  permit the action on the resource (`Samen.Scope.ApiKey.permits?/4`). It is the scope half of "the lower of
  the key's role and its scopes": the role half is the resource's own policies, which run alongside this one.

    * an actor with no `:api_key` (a signed-in person, a system actor, `nil`) is not a key request: the check
      is true and the resource's other policies decide;
    * an actor carrying an `:api_key` map needs a scope that covers the action's class (`read` for a read
      action, `write` for a create, update, destroy or generic action), the resource's family and its JSON:API
      type. A key with no scopes, or with a malformed scope map, is refused.

  `Samen.Transformers.ApiKeyScopePolicy` puts this check first in the policy list of every resource that is
  exposed over JSON:API, so a resource cannot forget it and a later `bypass` cannot skip it.
  """
  use Ash.Policy.SimpleCheck

  alias Samen.Scope.ApiKey

  @impl true
  def describe(_opts), do: "the API key's declared scopes permit this action"

  @impl true
  def match?(%{api_key: %{} = key}, %{resource: resource, action: %{type: type}}, _opts) do
    {:ok, ApiKey.permits?(key, ApiKey.action_class(type), ApiKey.family(resource), ApiKey.json_api_type(resource))}
  end

  def match?(%{api_key: _other}, _context, _opts), do: {:ok, false}
  def match?(_actor, _context, _opts), do: {:ok, true}
end
