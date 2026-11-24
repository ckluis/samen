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

  # A hand-rolled key lookup, caught by SHAPE rather than by one spelling. A file is a suspect when it
  # names an api-key resource (`ApiKey`, an alias of it, or an `…api_key` table) AND keys a read on
  # `token_digest` in any of the forms below. Spellings this catches (each has a control case below):
  #   * `ApiKey |> Ash.Query.filter(token_digest == ^d)`        (the original, newline or not)
  #   * `Ash.Query.filter(Mod, token_digest == ^d)`             (module as the FIRST argument)
  #   * `Key |> …` after `alias …ApiKey, as: Key`               (alias — the file still names ApiKey)
  #   * `Ash.read_one(Mod, …)` / `Ash.get(Mod, …, token_digest: d)` / `get_by: [token_digest: d]`
  #   * Ecto: `from k in "…api_key", where: k.token_digest == ^d`
  #   * the revoked filter first, digest second (any order: the digest filter is matched on its own)
  # What it cannot see: a lookup built in another file from a helper that hides `token_digest`. That is
  # why the known sites below are ALSO pinned to the shared query, and why this stays a tripwire.
  @names_a_key_resource ~r/ApiKey|[a-z_]*api_key\b/
  @keys_a_read_on_digest [
    # filter(…token_digest ==…) — module first or piped, other conditions before it, digest on its own line
    ~r/\bfilter\((?:[^()]|\([^()]*\))*?\btoken_digest\s*==/s,
    # Ecto: from k in "…api_key", where: k.token_digest == ^d
    ~r/\bwhere:[^\n]*\btoken_digest\s*==/,
    ~r/\bget_by\s*:\s*\[?\s*token_digest/,
    ~r/\bAsh\.get!?\([^\n]*\btoken_digest\b/
  ]

  # comments and docs name the lookup without being one; strip `# …` (not `#{…}` interpolation)
  defp code_only(src), do: Regex.replace(~r/(?m)(?<!#)#(?!\{).*$/, src, "")

  @doc false
  def hand_rolled_lookup?(src) do
    code = code_only(src)
    Regex.match?(@names_a_key_resource, code) and Enum.any?(@keys_a_read_on_digest, &Regex.match?(&1, code))
  end

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

  # the one module that BUILDS the lookup, and this guard's own detector text
  @allowed ~w(samen_core/lib/samen/scope/api_key.ex)

  test "no host lib or template hand-rolls an ApiKey token_digest lookup" do
    offenders =
      for file <- scanned_files(),
          rel = Path.relative_to(file, @root),
          rel not in @allowed,
          hand_rolled_lookup?(File.read!(file)),
          do: rel

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

  test "control: the detector flags every cheap evasion of the shared lookup and passes the shared one" do
    evasions = %{
      "original (pipe, newline)" => "PawChart.Operator.ApiKey\n|> Ash.Query.filter(token_digest == ^digest)\n",
      "module as the first filter argument" => "Ash.Query.filter(PawChart.Operator.ApiKey, token_digest == ^digest)",
      "alias" => "alias Demo.Identity.ApiKey, as: Key\nKey\n|> Ash.Query.filter(token_digest == ^d)",
      "revoked filter first" => "ApiKey |> Ash.Query.filter(is_nil(revoked_at)) |> Ash.Query.filter(token_digest == ^d)",
      "Ash.read_one with a filter" => "Ash.read_one(Ash.Query.filter(Demo.Identity.ApiKey, token_digest == ^d), authorize?: false)",
      "Ash.get by digest" => "Ash.get(Demo.Identity.ApiKey, %{token_digest: d}, get_by: [token_digest: d])",
      "get_by" => "Ash.get(Demo.Identity.ApiKey, get_by: [token_digest: d])",
      "Ecto from on the api_key table" => ~s|from(k in "dak_api_key", where: k.token_digest == ^d)|
    }

    for {name, src} <- evasions, do: assert(hand_rolled_lookup?(src), "the detector missed: #{name}")

    shared = "Samen.Scope.ApiKey.active_query(PawChart.Operator.ApiKey, digest)\n"
    refute hand_rolled_lookup?(shared)

    # control: a digest lookup on something that is NOT an api key is not flagged (invitations, auth tokens)
    refute hand_rolled_lookup?("Invitation |> Ash.Query.filter(token_digest == ^d)")
  end

  test "active_query/3 raises for a resource with no :expires_at that does not declare itself expiryless; the declaration is on the resource" do
    assert_raise ArgumentError, ~r/no :expires_at attribute and does not declare/, fn ->
      Samen.Scope.ApiKey.active_query(SamenCore.Support.Archivable.Widget, "digest")
    end

    refute function_exported?(Samen.Scope.ApiKey, :expiryless_resources, 0), "no host module is named in samen_core"
    refute File.read!(Path.join(@root, "samen_core/lib/samen/scope/api_key.ex")) =~ "Driftwood"
  end
end
