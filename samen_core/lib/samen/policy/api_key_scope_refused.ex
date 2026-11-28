defmodule Samen.Policy.ApiKeyScopeRefused do
  @moduledoc """
  The condition of the API-key scope policy: true ONLY for a key request (an actor carrying an `:api_key`) whose
  declared scopes do not permit the action (`Samen.Policy.ApiKeyScope`, negated).

  For every other actor (a signed-in person, a system actor, `nil`) and for a key whose scopes cover the action it is
  false, so the policy built on it does not apply to them and cannot be the one policy that makes Ash authorize a
  request: an action no policy the resource declares covers stays forbidden.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the API key's declared scopes do not permit this action"

  @impl true
  def match?(actor, context, opts) do
    {:ok, permitted?} = Samen.Policy.ApiKeyScope.match?(actor, context, opts)
    {:ok, not permitted?}
  end
end
