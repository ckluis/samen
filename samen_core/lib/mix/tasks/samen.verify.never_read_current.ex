defmodule Mix.Tasks.Samen.Verify.NeverReadCurrent do
  @shortdoc "Fail build on any un-marked read of a 'current' value from the CDC analytics tier."

  @moduledoc """
  `mix samen.verify.never_read_current` — the never-read-current lint (plan T6.5;
  doc line 635 "The rule that keeps both honest: never read a 'current' value from
  the analytics tier.").

  ## What it checks

  A read (`all/get/get_by/one/aggregate/exists?/…`) against the configured CDC
  analytics repo (`config :samen_core, :cdc, repo: …`) that sits in a module NOT
  marked `@cdc_analytics_read true` (or `use Samen.Cdc.Analytics`) is a
  `:current_read` violation. The analytics mirror is seconds-stale by construction;
  reading a value back and acting on it as *current* is a correctness bug the lint
  fails the build on.

  This is a dataflow *match* over Elixir source (NOT a sound proof — same honesty
  caveat as `pii_reads`). A read laundered through an opaque helper is an expected
  miss; keep CDC-repo reads syntactically visible and mark their module.

  ## Tier off (default)

  When no `:cdc` repo is configured the tier is off — there is no analytics repo to
  read, so the lint passes with an explicit "tier off" note (it does NOT fail
  vacuously — but it also does not pretend to have scanned an enabled mirror).

  ## What it scans

  Source files under `lib/` for the current mix project (override with
  `--source-dirs`).

  ## Exit code (fail-closed)

  Exits 0 when no `:current_read` and no `:parse_error` finding is present, 1
  otherwise (via `:erlang.halt/1`). `:laundered_hint` advisories are printed but
  never affect the exit code.

  ## Usage

      mix samen.verify.never_read_current
      mix samen.verify.never_read_current --source-dirs lib
  """

  use Mix.Task

  alias Samen.Cdc.NeverReadCurrent

  @task_name "samen.verify.never_read_current"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [source_dirs: [:string, :keep]])

    Mix.Task.run("app.start")

    repo = NeverReadCurrent.cdc_repo()

    if is_nil(repo) do
      IO.puts(
        "#{@task_name}: CDC analytics tier is OFF (no `config :samen_core, :cdc, repo: …`). " <>
          "Nothing to lint — never-read-current is vacuously satisfied (tier default off)."
      )
    else
      dirs =
        case Keyword.get_values(opts, :source_dirs) do
          [] -> ["lib"]
          list -> list
        end

      findings =
        dirs
        |> Enum.flat_map(fn dir ->
          {:ok, fs} = NeverReadCurrent.scan_dir(dir, repo)
          fs
        end)

      print_hints(Enum.filter(findings, &(&1.kind == :laundered_hint)))

      violations =
        findings
        |> Enum.filter(&(&1.kind in [:current_read, :parse_error]))
        |> Enum.map(fn f -> "#{f.file}:#{f.line} — #{f.message}" end)

      Samen.Verifier.halt_if_violations(@task_name, violations)
    end
  end

  defp print_hints([]), do: :ok

  defp print_hints(hints) do
    IO.puts("")
    IO.puts("#{@task_name}: #{length(hints)} laundered-flow hint(s) (advisory, non-failing):")
    Enum.each(hints, fn h -> IO.puts("  · #{h.file}:#{h.line} — #{h.message}") end)
  end
end
