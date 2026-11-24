defmodule Samen.ApiKeyLookupGuardTest do
  @moduledoc """
  Every host's API-key auth lookup must be built from `Samen.Scope.ApiKey.active_query/3`
  (digest + not revoked + not expired), so a host cannot forget a condition. pawchart's MCP
  resolver once filtered on digest + `revoked_at` only, so an EXPIRED key authenticated it.

  This guard fails if a host `lib/` or a generator template keys an `ApiKey` lookup on
  `token_digest` by hand, or if one of the known key-check sites stops using the shared query.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # a hand-rolled lookup: an `...ApiKey` module piped straight into a `token_digest` filter
  @bypass ~r/ApiKey\s*\n\s*\|>\s*Ash\.Query\.filter\(\s*token_digest/

  # every site that authenticates a bearer key, relative to the repo root
  @key_check_sites [
    "demo/lib/demo_web/api/key_auth_plug.ex",
    "driftwood/lib/driftwood_web/api/key_auth_plug.ex",
    "pawchart/lib/pawchart_web/api/mcp_key_resolver.ex",
    "samen_core/priv/templates/api_key_auth_plug_ex.eex"
  ]

  defp scanned_files do
    for dir <- ~w(demo/lib driftwood/lib pawchart/lib samen_web/lib samen_core/lib samen_core/priv/templates),
        file <- Path.wildcard(Path.join([@root, dir, "**", "*.{ex,eex}"])),
        do: file
  end

  test "no host lib or template hand-rolls an ApiKey token_digest lookup" do
    offenders =
      for file <- scanned_files(), File.read!(file) =~ @bypass, do: Path.relative_to(file, @root)

    assert offenders == [], "build the lookup with Samen.Scope.ApiKey.active_query/3: #{inspect(offenders)}"
  end

  test "every known key-check site resolves through the shared active_query" do
    for site <- @key_check_sites do
      path = Path.join(@root, site)
      assert File.exists?(path), "key-check site moved or vanished: #{site}"
      assert File.read!(path) =~ "Samen.Scope.ApiKey.active_query(", "#{site} bypasses the shared key lookup"
    end
  end

  test "every known key-check site refuses a role-less key and caps the role by the minter's current membership" do
    for site <- @key_check_sites, fun <- ["acting_role(", "effective_role("] do
      assert File.read!(Path.join(@root, site)) =~ "Samen.Scope.ApiKey." <> fun,
             "#{site} builds an actor without Samen.Scope.ApiKey.#{fun}…) (a nil-role or demoted-minter key would act with a stale role)"
    end
  end

  test "control: the detector flags a bypassing lookup and passes the shared one" do
    bypass = """
    PawChart.Operator.ApiKey
    |> Ash.Query.filter(token_digest == ^digest)
    |> Ash.Query.filter(is_nil(revoked_at))
    """

    shared = "Samen.Scope.ApiKey.active_query(PawChart.Operator.ApiKey, digest)\n"
    assert bypass =~ @bypass
    refute shared =~ @bypass
  end

  test "active_query/3 raises for a resource with no :expires_at that is not allowlisted; the allowlist is named" do
    assert_raise ArgumentError, ~r/no :expires_at attribute and is not in/, fn ->
      Samen.Scope.ApiKey.active_query(SamenCore.Support.Archivable.Widget, "digest")
    end

    assert Samen.Scope.ApiKey.expiryless_resources() == [Driftwood.Freight.ApiKey]
  end
end
