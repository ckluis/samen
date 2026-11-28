defmodule Demo.ApiKeyScopePathsGuardTest do
  @moduledoc """
  Every place that authenticates an API key either enforces the key's scopes or is named, in the `scopes` description
  of the identity blueprint and in ADR-029, as outside them.

  A key-authenticated request path is a file that builds its key lookup from `Samen.Scope.ApiKey.active_query/3` (the
  shared lookup every key-check site uses). It ENFORCES scopes when the actor it builds carries the resolved key as
  `api_key:`, because the policy every JSON:API resource carries reads it there. A path whose actor has no `api_key:`
  is outside the scopes, and the only such path allowed is the one listed below, which the description and the ADR
  must both name. A new key-check site that does neither fails this test.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  # path => the word the description and the ADR must use for it
  @outside %{"pawchart/lib/pawchart_web/api/mcp_key_resolver.ex" => "MCP"}

  # a CALL of `active_query(`, whatever the alias or import: its own definition and `@spec` are not a call
  @call ~r/^(?!\s*(?:def|defp|@spec)\s).*\bactive_query\(/m

  defp key_check?(source), do: source =~ @call

  defp sites do
    [
      "samen_core/lib/**/*.ex",
      "samen_web/lib/**/*.ex",
      "demo/lib/**/*.ex",
      "driftwood/lib/**/*.ex",
      "pawchart/lib/**/*.ex",
      "samen_core/priv/templates/*.eex"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.filter(&key_check?(File.read!(&1)))
    |> Enum.map(&Path.relative_to(&1, @root))
  end

  # code only: heredoc docs and `#` comments are stripped, but a `#{}` interpolation is not a comment
  defp code(rel) do
    (@root |> Path.join(rel) |> File.read!())
    |> String.replace(~r/@(?:module)?doc\s+(?:~[sS])?"""\n.*?"""/s, "")
    |> String.replace(~r/(?<!")#(?!\{).*$/m, "")
  end

  defp enforces?(rel), do: code(rel) =~ ~r/\bapi_key:\s*key\b/

  defp classify(sites, outside) do
    for rel <- sites, reduce: %{enforced: [], outside: [], unaccounted: []} do
      acc ->
        cond do
          enforces?(rel) -> Map.update!(acc, :enforced, &[rel | &1])
          Map.has_key?(outside, rel) -> Map.update!(acc, :outside, &[rel | &1])
          true -> Map.update!(acc, :unaccounted, &[rel | &1])
        end
    end
  end

  test "every key-authenticated request path enforces scopes or is named as outside them" do
    sites = sites()

    # anti-tautology: the scan reaches the real key-check sites
    for path <- [
          "demo/lib/demo_web/api/key_auth_plug.ex",
          "driftwood/lib/driftwood_web/api/key_auth_plug.ex",
          "pawchart/lib/pawchart_web/api/mcp_key_resolver.ex",
          "samen_core/priv/templates/api_key_auth_plug_ex.eex"
        ] do
      assert path in sites, "the key-path scan no longer reaches #{path}"
    end

    result = classify(sites, @outside)

    assert result.unaccounted == [],
           "a key-authenticated request path neither builds its actor with `api_key: key` (so the scope policy sees the key) " <>
             "nor is named as outside the scopes: enforce them there, or say so in the `scopes` description of the Identity " <>
             "blueprint, in ADR-029, and in @outside here: #{inspect(result.unaccounted)}"

    # every site classified as enforcing really does; every outside path really is outside (the list is not stale)
    assert Enum.sort(result.enforced ++ result.outside) == Enum.sort(sites)
    for rel <- Map.keys(@outside), do: refute(enforces?(rel), "#{rel} now carries the key: drop it from @outside")
  end

  test "the paths named as outside the scopes are named in the description and the ADR" do
    [table] = Enum.filter(Samen.AI.Catalog.schema()["tables"], &(&1["table_name"] == "key_api_key"))
    description = Enum.find(table["fields"], &(&1["logical_name"] == "scopes"))["description"]
    adr = File.read!(Path.join(@root, "docs/adr/ADR-029-self-serve-settings-scope-gated-self-edit.md"))

    for {_rel, word} <- @outside do
      assert description =~ word, "the `scopes` description does not name #{word}"
      assert adr =~ word, "ADR-029 does not name #{word}"
    end
  end

  test "the key-check matcher sees a call under any alias or import, and not the definition" do
    assert key_check?("Samen.Scope.ApiKey.active_query(R, d)")
    assert key_check?("alias Samen.Scope.ApiKey, as: K\n  K.active_query(R, d)")
    assert key_check?("import Samen.Scope.ApiKey\n  active_query(R, d)")
    refute key_check?("  def active_query(resource, digest) do")
    refute key_check?("  @spec active_query(module(), String.t()) :: term()")
    refute key_check?("Samen.Scope.ApiKey.active_query_other")
  end

  test "the guard is refutable: a key-check site that carries no key and is not listed is reported" do
    assert classify(["pawchart/lib/pawchart_web/api/mcp_key_resolver.ex"], %{}).unaccounted ==
             ["pawchart/lib/pawchart_web/api/mcp_key_resolver.ex"]

    assert classify(["pawchart/lib/pawchart_web/api/mcp_key_resolver.ex"], @outside).unaccounted == []
    assert classify(["demo/lib/demo_web/api/key_auth_plug.ex"], %{}).unaccounted == []
  end
end
