defmodule Samen.TestSandboxGuardTest do
  @moduledoc """
  ADR-053 P5 guard: no test file (and no emitted test template) may switch the SQL sandbox to shared mode by hand.

  The raw pair `Sandbox.checkout(repo)` + `Sandbox.mode(repo, {:shared, self()})` makes the TEST PROCESS the owner
  of the shared connection; the owner is gone before `on_exit` callbacks and any late async work run, which failed
  with `** (EXIT) shutdown: "owner … exited"` in ~110 modules' worth of CI flake surface. `Samen.TestSandbox.shared!/1`
  is the one sanctioned way (a dedicated owner that outlives the test process).

  Scanned: every `.ex`/`.exs` under `<app>/test/` of every project, `spikes/*/test`, `scripts/landing`, and the
  `.eex` templates `mix samen.gen.app` emits (a generated app must be born without the leak).
  Allowlist: `@demonstrates` — the files that must contain the raw pair ON PURPOSE. An entry whose file no longer
  contains it fails as OBSOLETE (the list only shrinks), and the scan must find the migrated call sites (a scan that
  finds nothing proves nothing).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  # the raw pair, single- or multi-line: Sandbox.mode(<repo expr>, {:shared, …})
  @raw ~r/Sandbox\.mode\(\s*[^,()]+,\s*\{:shared\s*,/

  @demonstrates ["samen_core/test/test_sandbox_test.exs"]
  # this file spells the raw pair in its own positive control
  @self "samen_core/test/meta/sandbox_shared_guard_test.exs"

  @helper_call ~r/Samen\.TestSandbox\.shared!\(/

  @doc false
  def raw_pair?(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&(&1 |> String.trim_leading() |> String.starts_with?("#")))
    |> Enum.join("\n")
    |> then(&Regex.match?(@raw, &1))
  end

  defp scanned_files do
    apps =
      ~w(samen_core samen_web demo driftwood pawchart samen_stripe samen_postmark samen_ses samen_resend samen_anthropic)

    globs =
      Enum.flat_map(apps, &["#{&1}/test/**/*.{ex,exs}"]) ++
        [
          "spikes/*/test/**/*.{ex,exs}",
          "scripts/landing/*.exs",
          "samen_core/priv/templates/*.eex"
        ]

    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.uniq()
    |> Enum.sort()
  end

  test "no test file or emitted template switches the sandbox to shared mode by hand" do
    offenders =
      for rel <- scanned_files(),
          rel not in @demonstrates,
          rel != @self,
          raw_pair?(File.read!(Path.join(@root, rel))),
          do: rel

    assert offenders == [],
           "raw `Sandbox.mode(repo, {:shared, …})` in:\n  " <>
             Enum.join(offenders, "\n  ") <>
             "\nuse `Samen.TestSandbox.shared!(repo)` (a dedicated owner that outlives the test process)"
  end

  test "positive control: the detector flags the raw pair in every spelling and passes the helper" do
    assert raw_pair?("    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})\n")
    assert raw_pair?("Sandbox.mode(@repo, {:shared, self()})")
    assert raw_pair?("Sandbox.mode(\n  Samen.WebTest.Repo,\n  {:shared, pid}\n)")
    assert raw_pair?("Ecto.Adapters.SQL.Sandbox.mode(Demo.Repo,{:shared, self()})")
    refute raw_pair?("    Samen.TestSandbox.shared!(TestRepo)\n")
    refute raw_pair?("    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)\n")

    refute raw_pair?(
             "# Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()}) in a comment\n"
           )
  end

  test "the scan is not vacuous: it sees the migrated suites and the demonstration file" do
    files = scanned_files()
    migrated = Enum.count(files, &Regex.match?(@helper_call, File.read!(Path.join(@root, &1))))

    assert migrated >= 100,
           "only #{migrated} files call Samen.TestSandbox.shared!/1 — the scan globs drifted"

    assert Enum.any?(files, &String.starts_with?(&1, "samen_web/test/"))
    assert Enum.any?(files, &String.starts_with?(&1, "demo/test/"))
    assert "samen_core/priv/templates/data_case.eex" in files
  end

  test "an allowlist entry that no longer holds the raw pair is OBSOLETE (the list only shrinks)" do
    for rel <- @demonstrates do
      source = File.read!(Path.join(@root, rel))

      assert raw_pair?(source),
             "#{rel} no longer contains the raw pair it exists to demonstrate: drop it from @demonstrates"
    end
  end
end
