defmodule Driftwood.DigestUniqueRetrofitDiscoveryTest do
  @moduledoc """
  The retrofit generators (`mix samen.gen.api_key_digest_unique`, `mix samen.gen.csat_token_digest_unique`) find their
  tables by DISCOVERY over the app's `:ash_domains`. In a real resource the attribute is the logical `:token_digest` and
  only the STORED column carries the abbrev prefix (`dak_token_digest`), so discovery must read the stored column. This asserts,
  on this host's REAL resources, that discovery finds exactly the table and column that the host's hand-written retrofit
  migration names, so the generator and the shipped migration can never disagree; and that, with the migration's
  unique index already in the app's migrations, the task writes nothing.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Samen.Gen.ApiKeyDigestUnique, as: Engine

  @migrations Path.expand("../priv/repo/migrations", __DIR__)

  # {table, column} pairs named by `concurrent_unique_index(:table, :column, …)` in the host's shipped migration
  defp shipped(file) do
    src = File.read!(Path.join(@migrations, file))

    ~r/concurrent_unique_index\(:(\w+),\s*:(\w+)/
    |> Regex.scan(src, capture: :all_but_first)
    |> Enum.map(fn [t, c] -> {t, c} end)
    |> Enum.sort()
  end

  defp domains, do: Application.fetch_env!(:driftwood, :ash_domains)

  for {kind, file} <- [api_key: "20261119120000_api_key_digest_unique.exs", csat: "20261120100000_csat_token_digest_unique.exs"] do
    @kind kind
    @mig_file file

    test "discovery of #{kind} tables finds exactly what the shipped migration names (table and stored column)" do
      expected = shipped(@mig_file)
      assert expected != []
      assert Enum.sort(Engine.discover(domains(), @kind)) == expected
      # the stored column differs from the logical attribute name: the shape discovery used to miss
      assert Enum.all?(expected, fn {_t, c} -> c != "token_digest" and String.ends_with?(c, "_token_digest") end)
    end

    test "with the shipped migration in place the #{kind} task writes nothing and says why" do
      keys = Engine.discover(domains(), @kind)
      before = Path.wildcard(Path.join(@migrations, "*.exs"))
      parent = self()

      out =
        ExUnit.CaptureIO.capture_io(fn ->
          send(parent, {:result, Engine.generate(Driftwood.Repo, keys, @migrations, "29990101000000", @kind)})
        end)

      assert_received {:result, nil}
      assert out =~ "already has a unique index in the migrations; skipped"
      assert out =~ "nothing to do"
      assert Path.wildcard(Path.join(@migrations, "*.exs")) == before
    end
  end
end
