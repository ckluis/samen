defmodule Samen.TestDbGuardTest do
  @moduledoc """
  Guard: no non-spike `.ex`/`.exs` file in the repo and no generator template may DISCARD the result of
  `Ecto.Adapters.Postgres.storage_down/1` (bare, `_ = …`, `_ignored = …`, piped), pair it with a bare
  `:ok = …storage_up(…)`, tolerate `{:error, :already_up} -> :ok`, or shell out to `ecto.drop`/`ecto.reset`; and no
  CI step, `*/ci.sh`, `scripts/*.sh`, `docs/runbooks/*.sh` or `*/priv/**/*.sh` may swallow a drop with `… ecto.drop … || true` / `dropdb … || true`.

  That is the pattern that failed `ci (app_demo)` with `{:error, :already_up}`: the drop failed, `_ =` threw its error
  away, and `storage_up` answered `:already_up`. The cause was never recorded (see the `Samen.TestDb` moduledoc for
  the two candidates). `Samen.TestDb.reset!/1` / `drop!/1` wait for the server and raise with the real error; they
  are the one sanctioned way (`Samen.TestDbTest`). `mix ecto.drop` in a CI step is allowed only with its exit status
  intact (it exits 0 for a database that does not exist, so `|| true` could only ever hide a real failure).

  Scanned: `lib`, `test`, `config`, `priv` (scripts and templates) of every project, `scripts/`, and the emitted
  `.eex` templates plus the generator modules that embed them; shell: `ci/steps.conf`, `ci.sh`, `*/ci.sh`,
  `scripts/*.sh`, `docs/runbooks/*.sh`, `*/priv/**/*.sh`. `spikes/` is frozen and not scanned.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  # a `storage_down(` whose result is dropped: a statement of its own, `_ = …`, `_ignored = …`, or piped (`x |> …storage_down()`)
  @discarded_down ~r/^\s*(?:_\w*\s*=\s*)?[\w.()@]*storage_down\(|\|>\s*[\w.()@]*storage_down\(/m
  # a bare `:ok = …storage_up(` match (a MatchError on `{:error, :already_up}`)
  @bare_up ~r/:ok\s*=\s*[\w.()@]*storage_up\(/
  # `{:error, :already_up} -> :ok`: the tolerance twin (a database nobody dropped is accepted as fresh)
  @tolerated_up ~r/\{:error,\s*:already_up\}\s*->\s*:ok/
  # running the mix task from Elixir code (its failure is also easy to drop)
  @mix_drop ~r/Mix\.Task\.(?:run|rerun)\(\s*"ecto\.(?:drop|reset)"/
  # shell: a drop whose failure is swallowed
  @shell_swallowed ~r/(?:ecto\.drop|ecto\.reset|dropdb|DROP DATABASE)\b[^\n]*\|\|\s*true\b/i

  # this file spells the patterns in its own positive controls
  @self "samen_core/test/meta/test_db_guard_test.exs"

  defp strip_comments(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  @doc false
  def raw_pattern?(source) when is_binary(source) do
    code = strip_comments(source)

    Enum.any?([@discarded_down, @bare_up, @tolerated_up, @mix_drop], &Regex.match?(&1, code))
  end

  @doc false
  def swallowed_drop?(source) when is_binary(source), do: Regex.match?(@shell_swallowed, strip_comments(source))

  # Every walk and read goes through Samen.SourceScan (:prim_file): `Path.wildcard` (one `**` walk per app x dir x extension,
  # 122 globs) and `File.read!` (~2,400 files) are each a call into the node's single `:file_server_2`, which queues behind
  # every other test's file I/O -- this test passed in ~1 s alone and outran ExUnit's 60 s at load ~14.
  @apps ~w(samen_core samen_web demo driftwood pawchart samen_stripe samen_postmark samen_ses samen_resend samen_anthropic)
  @skipped ["/deps/", "/_build/", "/spikes/", "/node_modules/"]

  defp scanned_files do
    tree =
      for app <- @apps, dir <- ~w(lib test config priv), file <- Samen.SourceScan.files(Path.join([@root, app, dir]), ~w(.ex .exs .eex)), do: file

    scripts = Samen.SourceScan.files(Path.join(@root, "scripts"), ~w(.ex .exs))
    top = for f <- flat(@root), String.ends_with?(f, ".exs"), do: f

    relative(tree ++ scripts ++ top)
  end

  defp shell_files do
    star_ci = for dir <- Samen.SourceScan.dirs(@root, "*"), f = Path.join(dir, "ci.sh"), regular?(f), do: f
    privs = for dir <- Samen.SourceScan.dirs(@root, "*/priv"), f <- Samen.SourceScan.files(dir, [".sh"]), do: f

    fixed =
      for rel <- ~w(ci/steps.conf ci.sh ci-fast.sh), f = Path.join(@root, rel), regular?(f), do: f

    flat_sh = for dir <- ~w(scripts docs/runbooks), f <- flat(Path.join(@root, dir)), String.ends_with?(f, ".sh"), do: f

    relative(fixed ++ star_ci ++ flat_sh ++ privs)
  end

  # the regular files directly in `dir` (what `dir/*` matched: dot-entries skipped), full paths
  defp flat(dir) do
    case :prim_file.list_dir(dir) do
      {:ok, names} ->
        for name <- Enum.map(names, &to_string/1), not String.starts_with?(name, "."), regular?(Path.join(dir, name)), do: Path.join(dir, name)

      {:error, _} ->
        []
    end
  end

  defp regular?(path), do: match?({:ok, info} when elem(info, 2) == :regular, :prim_file.read_file_info(path))

  defp relative(paths) do
    paths
    |> Enum.reject(&String.contains?(&1, @skipped))
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp read!(rel), do: Samen.SourceScan.read!(Path.join(@root, rel))

  test "no source or template discards storage_down, tolerates :already_up, or pairs it with a bare :ok = storage_up" do
    offenders =
      for rel <- scanned_files(), rel != @self, raw_pattern?(read!(rel)), do: rel

    assert offenders == [],
           "storage_down result discarded / :already_up tolerated / bare `:ok = …storage_up` / ecto.drop task in:\n  " <>
             Enum.join(offenders, "\n  ") <>
             "\nuse `Samen.TestDb.reset!(config)` / `Samen.TestDb.drop!(config)` (waits for the server, raises with the real error)"
  end

  test "no CI step or script swallows a database drop with `|| true`" do
    offenders =
      for rel <- shell_files(), swallowed_drop?(read!(rel)), do: rel

    assert offenders == [],
           "a drop whose failure is swallowed (`… || true`) in:\n  " <>
             Enum.join(offenders, "\n  ") <>
             "\n`mix ecto.drop` exits 0 for a missing database, so `|| true` only hides real failures; let it fail"
  end

  test "positive control: the detector flags the pattern in every spelling and passes the helper" do
    assert raw_pattern?("_ = Ecto.Adapters.Postgres.storage_down(Repo.config())\n")
    assert raw_pattern?("    _ = Ecto.Adapters.Postgres.storage_down(config)\n")
    assert raw_pattern?("    Ecto.Adapters.Postgres.storage_down(config)\n    :ok\n")
    assert raw_pattern?("_ = repo.__adapter__().storage_down(repo.config())")
    assert raw_pattern?("on_exit(fn ->\n  _ = Ecto.Adapters.Postgres.storage_down(config)\nend)")
    assert raw_pattern?(":ok = Ecto.Adapters.Postgres.storage_up(Repo.config())")
    assert raw_pattern?("    :ok   = Ecto.Adapters.Postgres.storage_up(config)")
    # named discard
    assert raw_pattern?("_ignored = Ecto.Adapters.Postgres.storage_down(config)")
    assert raw_pattern?("_result = Ecto.Adapters.Postgres.storage_down(config)")
    # piped
    assert raw_pattern?("config |> Ecto.Adapters.Postgres.storage_down()")
    assert raw_pattern?("config\n|> Ecto.Adapters.Postgres.storage_down()\n:ok")
    # tolerated already_up
    assert raw_pattern?("case storage_up(c) do\n  :ok -> :ok\n  {:error, :already_up} -> :ok\nend")
    assert raw_pattern?("{:error, :already_up}\n  -> :ok")
    # the mix task run from code
    assert raw_pattern?(~s|Mix.Task.run("ecto.drop", ["--quiet"])|)
    assert raw_pattern?(~s|Mix.Task.rerun("ecto.reset")|)
    refute raw_pattern?(":ok = Samen.TestDb.reset!(Repo.config())\n")
    refute raw_pattern?("Samen.TestDb.drop!(config)\n")
    refute raw_pattern?("    # _ = Ecto.Adapters.Postgres.storage_down(config) in a comment\n")
    refute raw_pattern?("case Ecto.Adapters.Postgres.storage_down(config) do\n  :ok -> :ok\nend")
    refute raw_pattern?("assert {:error, msg} = Ecto.Adapters.Postgres.storage_down(config)")
    refute raw_pattern?("case storage_up(c) do\n  {:error, :already_up} -> raise \"stale\"\nend")
    refute raw_pattern?(~s|Mix.Task.run("ecto.migrate")|)
  end

  test "positive control: the shell detector flags a swallowed drop in every spelling and passes a checked one" do
    assert swallowed_drop?("    MIX_ENV=test mix ecto.drop --quiet || true\n")
    assert swallowed_drop?("cmd = MIX_ENV=test mix ecto.drop --quiet || true")
    assert swallowed_drop?("mix ecto.drop --quiet  ||  true")
    assert swallowed_drop?(~S{dropdb --if-exists "$SRC_DB" >/dev/null 2>&1 || true})
    assert swallowed_drop?(~S{psql -c "DROP DATABASE IF EXISTS x" || true})
    assert swallowed_drop?(~S'drop_db()   { psql_admin "DROP DATABASE IF EXISTS $1" >/dev/null 2>&1 || true; }')
    refute swallowed_drop?("    MIX_ENV=test mix ecto.drop --quiet\n    MIX_ENV=test mix ecto.create --quiet\n")
    refute swallowed_drop?(~S{dropdb --if-exists "$X" || echo "WARNING: could not drop" >&2})
    refute swallowed_drop?(~S'drop_db() { psql_admin "DROP DATABASE IF EXISTS $1" >/dev/null || fail "could not drop $1"; }')
    refute swallowed_drop?("# mix ecto.drop --quiet || true (commented out)")
    refute swallowed_drop?("rm -rf tmp || true")
  end

  test "the scan is not vacuous: it sees the hosts, the templates and the helper's callers" do
    files = scanned_files()
    assert "demo/test/test_helper.exs" in files
    assert "pawchart/priv/ci_bootstrap.exs" in files
    assert "samen_core/priv/templates/test_helper.eex" in files
    assert "samen_core/lib/mix/tasks/samen.verify.migrations.ex" in files
    assert "samen_core/lib/samen/gen/post_templates.ex" in files
    refute Enum.any?(files, &String.starts_with?(&1, "spikes/"))

    shell = shell_files()
    assert "ci/steps.conf" in shell
    assert "demo/ci.sh" in shell
    assert "scripts/backup-verify-gameday.sh" in shell
    assert "docs/runbooks/pitr-gameday-sim.sh" in shell
    assert "driftwood/priv/gameday/pitr_gameday_sim.sh" in shell
    assert Regex.match?(~r/mix ecto\.drop/, read!("ci/steps.conf"))
  end
end
