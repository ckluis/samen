defmodule Samen.Meta.StrictCompileForceTest do
  @moduledoc """
  Every strict compile in CI is a FORCED recompile of the app's own code.

  #108 merged green locally and broke main: a Spark DSL verifier warning (a fixture action
  that could not be atomic) was printed once by a non-strict compile, and every later
  `mix compile --warnings-as-errors` was incremental and never raised it again. Neither a
  touched source (Mix compares digests), a deleted `.beam` (Mix trusts its manifest) nor
  `--all-warnings` (verifier warnings are not stored diagnostics) brings it back. Actions
  compiles from scratch and caught it. `--force` recompiles the app's own code only (not
  its dependencies): about 7 s for samen_core's 628 files.

  This reads every place CI runs a strict compile (`ci/steps.conf`, each app's `ci.sh`, the
  generator's `ci.sh` templates and their goldens) and refuses one without `--force`.
  """
  use ExUnit.Case, async: true

  @repo Path.expand("../../..", __DIR__)

  @strict ~r/mix compile\b[^\n&|]*--warnings-as-errors/

  defp sources do
    steps = Path.join(@repo, "ci/steps.conf")

    app_scripts =
      for app <- ~w(demo driftwood pawchart samen_web), do: Path.join([@repo, app, "ci.sh"])

    templates =
      Path.wildcard(Path.join(@repo, "samen_core/priv/templates/ci_sh*.eex")) ++
        Path.wildcard(
          Path.join(@repo, "samen_core/test/fixtures/templates_golden/*/ci.sh.golden")
        )

    [steps | app_scripts] ++ templates
  end

  # Every executable strict compile: comments and `echo` labels are not commands.
  defp strict_compiles(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} -> String.match?(line, ~r/^\s*(#|echo )/) end)
    |> Enum.filter(fn {line, _} -> Regex.match?(@strict, line) end)
  end

  test "every strict compile in CI forces a recompile of the app's own code" do
    found = for path <- sources(), {line, n} <- strict_compiles(path), do: {path, n, line}

    # ANTI-VACUITY: the six direct app steps, four app ci.sh files, two templates and five
    # goldens — a renamed file or a changed command shape must not turn this green on nothing.
    assert length(found) >= 17, "found only #{length(found)} strict compiles:\n#{inspect(found)}"

    unforced =
      for {path, n, line} <- found,
          not String.contains?(line, "--force"),
          do: "#{Path.relative_to(path, @repo)}:#{n}: #{String.trim(line)}"

    assert unforced == [],
           "a strict compile without --force passes on a warm _build that hides Spark verifier " <>
             "warnings (see this module's doc):\n" <> Enum.join(unforced, "\n")
  end
end
