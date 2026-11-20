defmodule Samen.TestDbGuardTest do
  @moduledoc """
  Guard: no non-spike `.ex`/`.exs` file in the repo and no generator template may DISCARD the result of
  `Ecto.Adapters.Postgres.storage_down/1` (bare, `_ = …`, `_ignored = …`, piped), pair it with a bare
  `:ok = …storage_up(…)`, tolerate `{:error, :already_up} -> :ok`, or shell out to `ecto.drop`/`ecto.reset`; and no
  CI step, `*/ci.sh` or `scripts/*.sh` may swallow a drop with `… ecto.drop … || true` / `dropdb … || true`.

  That is the pattern that failed `ci (app_demo)` with `{:error, :already_up}`: the drop failed, `_ =` threw its error
  away, and `storage_up` answered `:already_up`. The cause was never recorded (see the `Samen.TestDb` moduledoc for
  the two candidates). `Samen.TestDb.reset!/1` / `drop!/1` wait for the server and raise with the real error; they
  are the one sanctioned way (`Samen.TestDbTest`). `mix ecto.drop` in a CI step is allowed only with its exit status
  intact (it exits 0 for a database that does not exist, so `|| true` could only ever hide a real failure).

  Scanned: `lib`, `test`, `config`, `priv` (scripts and templates) of every project, `scripts/`, and the emitted
  `.eex` templates plus the generator modules that embed them; shell: `ci/steps.conf`, `ci.sh`, `*/ci.sh`,
  `scripts/*.sh`. `spikes/` is frozen and not scanned.
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

  defp scanned_files do
    apps = ~w(samen_core samen_web demo driftwood pawchart samen_stripe samen_postmark samen_ses samen_resend samen_anthropic)

    globs =
      Enum.flat_map(apps, fn app ->
        for dir <- ~w(lib test config priv), ext <- ~w(ex exs eex), do: "#{app}/#{dir}/**/*.#{ext}"
      end) ++ ["scripts/**/*.{ex,exs}", "*.exs"]

    relative(globs)
  end

  defp shell_files do
    relative(["ci/steps.conf", "ci.sh", "ci-fast.sh", "*/ci.sh", "scripts/*.sh"])
  end

  defp relative(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.reject(&String.contains?(&1, ["/deps/", "/_build/", "/spikes/", "/node_modules/"]))
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "no source or template discards storage_down, tolerates :already_up, or pairs it with a bare :ok = storage_up" do
    offenders =
      for rel <- scanned_files(), rel != @self, raw_pattern?(File.read!(Path.join(@root, rel))), do: rel

    assert offenders == [],
           "storage_down result discarded / :already_up tolerated / bare `:ok = …storage_up` / ecto.drop task in:\n  " <>
             Enum.join(offenders, "\n  ") <>
             "\nuse `Samen.TestDb.reset!(config)` / `Samen.TestDb.drop!(config)` (waits for the server, raises with the real error)"
  end

  test "no CI step or script swallows a database drop with `|| true`" do
    offenders =
      for rel <- shell_files(), swallowed_drop?(File.read!(Path.join(@root, rel))), do: rel

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
    refute swallowed_drop?("    MIX_ENV=test mix ecto.drop --quiet\n    MIX_ENV=test mix ecto.create --quiet\n")
    refute swallowed_drop?(~S{dropdb --if-exists "$X" || echo "WARNING: could not drop" >&2})
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
    assert Regex.match?(~r/mix ecto\.drop/, File.read!(Path.join(@root, "ci/steps.conf")))
  end
end
