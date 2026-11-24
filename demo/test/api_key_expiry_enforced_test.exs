defmodule Demo.ApiKeyExpiryEnforcedTest do
  @moduledoc """
  The guard over this host's key-check site: the resource its key lookup authenticates against enforces expiry
  (`Samen.Scope.ApiKey.expiry_enforced?/1`), and building that lookup does not raise. A column renamed away from
  `:expires_at` fails HERE (CI), not as a 500 on every request.
  """
  use ExUnit.Case, async: true

  test "Demo.Identity.ApiKey enforces expiry and its lookup builds" do
    assert Samen.Scope.ApiKey.expiry_enforced?(Demo.Identity.ApiKey)
    assert %Ash.Query{} = Samen.Scope.ApiKey.active_query(Demo.Identity.ApiKey, "digest")
  end
end
