defmodule Driftwood.ApiKeyExpiryEnforcedTest do
  @moduledoc """
  The guard over this host's key-check site (`DriftwoodWeb.Api.KeyAuthPlug`, `Driftwood.Freight.ApiKey`): the
  resource has no `:expires_at` column and DECLARES it (`samen_key_expiryless?/0`), so building its lookup does
  not raise and does not filter on expiry; the settings mint's `Driftwood.Operator.ApiKey` enforces expiry. A
  resource that neither has the column nor declares itself raises (`api_key_lookup_guard_test.exs` in samen_core),
  so a forgotten column fails in CI, not as a 500 on every request.
  """
  use ExUnit.Case, async: true

  test "the Freight key resource declares itself expiryless and its lookup builds; the Identity key enforces expiry" do
    refute Samen.Scope.ApiKey.expiry_enforced?(Driftwood.Freight.ApiKey)
    assert %Ash.Query{} = Samen.Scope.ApiKey.active_query(Driftwood.Freight.ApiKey, "digest")

    assert Samen.Scope.ApiKey.expiry_enforced?(Driftwood.Operator.ApiKey)
  end
end
