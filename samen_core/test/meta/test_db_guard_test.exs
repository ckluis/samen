defmodule Samen.TestDbGuardTest do
  @moduledoc """
  Guard: no non-spike `.ex`/`.exs` file in the repo and no generator template may DISCARD the result of
  `Ecto.Adapters.Postgres.storage_down/1` or pair it with a bare `:ok = ….storage_up(…)`.

  That pair is the race that failed `ci (app_demo)` with `{:error, :already_up}`: a backend of the previous mix
  process had not exited, so the drop failed ("database … is being accessed by other users"), `_ =` threw the reason
  away, and `storage_up` answered `:already_up`. `Samen.TestDb.reset!/1` / `drop!/1` drop with `WITH (FORCE)` and
  raise with the real error; they are the one sanctioned way (`Samen.TestDbTest`).

  Scanned: `lib`, `test`, `config`, `priv` (scripts and templates) of every project, `scripts/`, and the emitted
  `.eex` templates plus the generator modules that embed them. `spikes/` is frozen and not scanned.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  # a `storage_down(` whose result is dropped: a statement of its own, or `_ = …storage_down(`
  @discarded_down ~r/^\s*(?:_\s*=\s*)?[\w.()@]*storage_down\(/m
  # a bare `:ok = …storage_up(` match (a MatchError on `{:error, :already_up}`)
  @bare_up ~r/:ok\s*=\s*[\w.()@]*storage_up\(/

  # this file spells the pattern in its own positive control
  @self "samen_core/test/meta/test_db_guard_test.exs"

  @doc false
  def raw_pattern?(source) when is_binary(source) do
    code =
      source
      |> String.split("\n")
      |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))
      |> Enum.join("\n")

    Regex.match?(@discarded_down, code) or Regex.match?(@bare_up, code)
  end

  defp scanned_files do
    apps = ~w(samen_core samen_web demo driftwood pawchart samen_stripe samen_postmark samen_ses samen_resend samen_anthropic)

    globs =
      Enum.flat_map(apps, fn app ->
        for dir <- ~w(lib test config priv), ext <- ~w(ex exs eex), do: "#{app}/#{dir}/**/*.#{ext}"
      end) ++ ["scripts/**/*.{ex,exs}", "*.exs"]

    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.reject(&String.contains?(&1, ["/deps/", "/_build/", "/spikes/", "/node_modules/"]))
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "no source or template discards storage_down or pairs it with a bare :ok = storage_up" do
    offenders =
      for rel <- scanned_files(), rel != @self, raw_pattern?(File.read!(Path.join(@root, rel))), do: rel

    assert offenders == [],
           "storage_down result discarded / bare `:ok = …storage_up` in:\n  " <>
             Enum.join(offenders, "\n  ") <>
             "\nuse `Samen.TestDb.reset!(config)` / `Samen.TestDb.drop!(config)` (FORCE drop, raises with the real error)"
  end

  test "positive control: the detector flags the pattern in every spelling and passes the helper" do
    assert raw_pattern?("_ = Ecto.Adapters.Postgres.storage_down(Repo.config())\n")
    assert raw_pattern?("    _ = Ecto.Adapters.Postgres.storage_down(config)\n")
    assert raw_pattern?("    Ecto.Adapters.Postgres.storage_down(config)\n    :ok\n")
    assert raw_pattern?("_ = repo.__adapter__().storage_down(repo.config())")
    assert raw_pattern?("on_exit(fn ->\n  _ = Ecto.Adapters.Postgres.storage_down(config)\nend)")
    assert raw_pattern?(":ok = Ecto.Adapters.Postgres.storage_up(Repo.config())")
    assert raw_pattern?("    :ok   = Ecto.Adapters.Postgres.storage_up(config)")
    refute raw_pattern?(":ok = Samen.TestDb.reset!(Repo.config())\n")
    refute raw_pattern?("Samen.TestDb.drop!(config)\n")
    refute raw_pattern?("    # _ = Ecto.Adapters.Postgres.storage_down(config) in a comment\n")
    refute raw_pattern?("case Ecto.Adapters.Postgres.storage_down(config) do\n  :ok -> :ok\nend")
    refute raw_pattern?("assert {:error, msg} = Ecto.Adapters.Postgres.storage_down(config)")
  end

  test "the scan is not vacuous: it sees the hosts, the templates and the helper's callers" do
    files = scanned_files()
    assert "demo/test/test_helper.exs" in files
    assert "pawchart/priv/ci_bootstrap.exs" in files
    assert "samen_core/priv/templates/test_helper.eex" in files
    assert "samen_core/lib/mix/tasks/samen.verify.migrations.ex" in files
    assert "samen_core/lib/samen/gen/post_templates.ex" in files
    refute Enum.any?(files, &String.starts_with?(&1, "spikes/"))
  end
end
