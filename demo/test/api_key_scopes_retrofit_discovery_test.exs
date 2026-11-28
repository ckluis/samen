defmodule Demo.ApiKeyScopesRetrofitDiscoveryTest do
  @moduledoc """
  `mix samen.gen.api_key_scopes` finds its tables by DISCOVERY over the app's `:ash_domains`. This asserts, on this host's REAL
  resources, that discovery finds exactly the tables and STORED columns the host's shipped backfill migration names (so the
  generator and the migration can never disagree), that the migration really contains both statements for each, and that with
  it in place the task writes nothing.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Samen.Gen.ApiKeyScopes, as: Engine

  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @file_name "20261127100000_api_key_scopes.exs"

  defp domains, do: Application.fetch_env!(:demo, :ash_domains)

  test "discovery finds exactly the tables and stored columns the shipped migration backfills" do
    src = File.read!(Path.join(@migrations, @file_name))
    expected = Engine.discover(domains())

    assert expected != []

    for {table, scopes, role} <- expected do
      assert src =~ "chunked_backfill(repo(), \"#{table}\", ~s|#{scopes} = '{\"all\":[\"read\",\"write\"]}'::jsonb|"
      assert src =~ "#{role} IN ('owner', 'admin', 'member')"
      assert src =~ "#{scopes} = '{\"all\":[\"read\"]}'::jsonb"
      assert src =~ "#{role} = 'viewer'"
      # the stored columns differ from the logical attribute names: the shape discovery must read
      assert scopes != "scopes" and role != "minter_role"
    end
  end

  test "with the shipped migration in place the task writes nothing and says why" do
    keys = Engine.discover(domains())
    scratch = Path.join(System.tmp_dir!(), "samen_scopes_retrofit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch)
    on_exit(fn -> File.rm_rf!(scratch) end)
    for f <- Path.wildcard(Path.join(@migrations, "*.exs")), do: File.cp!(f, Path.join(scratch, Path.basename(f)))
    before = Path.wildcard(Path.join(scratch, "*.exs"))
    parent = self()

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        send(parent, {:result, Engine.generate(Demo.Repo, keys, scratch, "29990101000000")})
      end)

    assert_received {:result, nil}
    assert out =~ "is already backfilled by a migration; skipped"
    assert out =~ "nothing to do"
    assert Path.wildcard(Path.join(scratch, "*.exs")) == before
  end
end
