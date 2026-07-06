defmodule Samen.Migration.DownCheck do
  @moduledoc """
  The expand-`down/0` CI check (T2.4a).

  The doc's expand phase is reversible "because it is additive — every expand
  migration ships a tested `down/0`" (§runs 2b). This module makes "tested" a CI
  fact rather than a hope: it **exercises every `:expand` migration's `down/0` in a
  scratch database** and fails closed if a down is missing, raises, or leaves the
  scratch DB unable to re-migrate forward.

  The irreversible `:contract` phase is deliberately NOT down-tested here — the doc
  covers it by PITR, not `down/0` (§runs 2b). A migration with no `phase:` is treated
  as a plain migration and skipped (only phase-tagged expands are in scope).

  ## What it does

  Against a **scratch** repo/database (never production, never the dev DB):

    1. Migrate all the way up (`Ecto.Migrator.run(:up, all: true)`).
    2. For each `:expand` migration, in reverse-version order:
       a. `Ecto.Migrator.run(:down, to: <this version - 1>)` — rolls the applied
          stack down THROUGH this expand (running this expand's `down/0`, and the
          `down/0` of any migration applied above it). Using `to:` rather than
          `step: 1` makes the check robust to non-expand migrations layered on top
          of an expand (e.g. a later scope-mount migration): stepping by 1 would peel
          the newest applied migration, not the expand under test.
       b. Assert this expand's version is among the rolled-back set (its `down/0`
          actually ran).
       c. `Ecto.Migrator.run(:up, all: true)` — re-apply the whole stack, asserting
          the pair is a clean round trip (down then up does not error) and restoring
          full state for the next (older) expand's turn.
    3. Any raise / missing-down / non-reversible op is a violation.

  A migration whose `up/0` is not reversible (no `down/0`, or a `change/0` with a
  non-reversible op like a raw `execute/1`) makes `Ecto.Migrator.run(:down, ...)`
  raise `Ecto.MigrationError` — which this check catches and reports as a broken
  down. That is the "down/0 CI check catches an expand with a broken down" red path.

  ## Discovery

  `expand_migrations/1` reads the migrations directory and keeps those whose file
  SOURCE declares `use Samen.Migration, phase: :expand`. Discovery is source-level
  (regex) on purpose: `Ecto.Migrator` compiles the migration files during `run/3`,
  and a second `Code.compile_file` for discovery would emit a "redefining module"
  warning that `mix test --warnings-as-errors` fails on. Non-`Samen.Migration`
  migrations (or ones without `phase:`) are treated as un-phased and skipped.

  ## Usage

  Invoked by `mix samen.verify.migrations` (which sets up an ephemeral scratch DB).
  Callable directly in tests with a pre-built scratch repo.
  """

  @doc """
  Return `{:ok, checked}` if every `:expand` migration under `migrations_path` has a
  working `down/0`, else `{:error, violations}`.

  `repo` MUST be a scratch repo pointed at a throwaway database — this function
  migrates it down and up. `checked` is the list of expand migration versions
  exercised.

  ## Options

    * `:log` — Ecto migrator log level (default `false`, silent).
  """
  def run(repo, migrations_path, opts \\ []) do
    # `Ecto.Migrator` compiles migration files on each up/down run. Because the check
    # runs each expand down-then-up, the same migration module is compiled more than
    # once in this process, which emits a "redefining module" warning that
    # `mix test --warnings-as-errors` fails on. The migration modules are throwaway
    # scratch fixtures, so tolerate the redefinition here (scoped, restored after).
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      do_run(repo, migrations_path, opts)
    after
      Code.put_compiler_option(:ignore_module_conflict, previous || false)
    end
  end

  defp do_run(repo, migrations_path, opts) do
    log = Keyword.get(opts, :log, false)

    expands = expand_migrations(migrations_path)

    # Bring the scratch DB fully up first.
    Ecto.Migrator.run(repo, migrations_path, :up, all: true, log: log)

    {checked, violations} =
      expands
      # Exercise in reverse version order so stepping down peels the newest first.
      |> Enum.sort_by(& &1.version, :desc)
      |> Enum.reduce({[], []}, fn mig, {checked_acc, viol_acc} ->
        case exercise_down(repo, migrations_path, mig, log) do
          :ok -> {[mig.version | checked_acc], viol_acc}
          {:violation, msg} -> {checked_acc, [msg | viol_acc]}
        end
      end)

    case Enum.reverse(violations) do
      [] -> {:ok, Enum.sort(checked)}
      v -> {:error, v}
    end
  end

  @doc """
  Discover `:expand`-phase migrations under `migrations_path`.

  Returns a list of `%{version: integer, name: binary, file: path}`. Discovery reads
  the migration file SOURCE for the `use Samen.Migration, phase: :expand` declaration
  — it deliberately does NOT compile the files, because `Ecto.Migrator` compiles them
  during `run/3` and a second `Code.compile_file` would emit a "redefining module"
  warning that `mix test --warnings-as-errors` fails on. Source-level discovery keeps
  compilation solely owned by Ecto.

  Migrations without a `phase:` (plain `use Ecto.Migration`, or `use Samen.Migration`
  without `phase:`) are excluded.
  """
  def expand_migrations(migrations_path) do
    migrations_path
    |> migration_files()
    |> Enum.map(&load_migration/1)
    |> Enum.filter(fn %{phase: phase} -> phase == :expand end)
  end

  @doc """
  The declared phase of a migration, read from its file source. Returns `:expand`,
  `:contract`, or `nil`.
  """
  def phase_of_file(file) do
    source = File.read!(file)

    cond do
      Regex.match?(~r/use\s+Samen\.Migration\s*,[^\n]*phase:\s*:expand/, source) -> :expand
      Regex.match?(~r/use\s+Samen\.Migration\s*,[^\n]*phase:\s*:contract/, source) -> :contract
      true -> nil
    end
  end

  # ---------------------------------------------------------------------------

  # Roll the applied stack down through this expand (running its down/0), then bring
  # everything back up. Using `:down, to: version - 1` (rather than `:step, 1`) makes
  # the check robust to NON-expand migrations layered on top of an expand — stepping
  # by one would peel the newest applied migration, which may not be the expand under
  # test (e.g. a later scope-mount migration). Rolling `to:` version-1 guarantees this
  # expand's down/0 runs, regardless of what sits above it.
  defp exercise_down(repo, migrations_path, %{version: version, name: module}, log) do
    try do
      rolled = Ecto.Migrator.run(repo, migrations_path, :down, to: version - 1, log: log)

      if version in rolled do
        # Re-apply the whole stack to restore state for the next (older) expand's turn.
        case Ecto.Migrator.run(repo, migrations_path, :up, all: true, log: log) do
          reapplied when is_list(reapplied) ->
            if version in reapplied do
              :ok
            else
              {:violation,
               "#{inspect(module)} (v#{version}): re-apply after down did not re-run this " <>
                 "migration (re-applied #{inspect(reapplied)}) — down/0 is not a clean round trip."}
            end
        end
      else
        {:violation,
         "#{inspect(module)} (v#{version}): rolling down to v#{version - 1} did not roll back " <>
           "this expand (rolled #{inspect(rolled)}) — check migration ordering / down/0."}
      end
    rescue
      e in [Ecto.MigrationError, Postgrex.Error, DBConnection.ConnectionError, RuntimeError] ->
        {:violation,
         "#{inspect(module)} (v#{version}): down/0 FAILED — #{Exception.message(e)}. " <>
           "Every :expand migration must ship a tested, reversible down/0 (doc §runs 2b)."}
    end
  end

  defp migration_files(migrations_path) do
    migrations_path
    |> File.ls!()
    |> Enum.filter(&String.match?(&1, ~r/^\d+_.+\.exs$/))
    |> Enum.map(&Path.join(migrations_path, &1))
    |> Enum.sort()
  end

  defp load_migration(file) do
    basename = Path.basename(file)

    version =
      basename
      |> String.split("_", parts: 2)
      |> hd()
      |> String.to_integer()

    %{version: version, name: basename, phase: phase_of_file(file), file: file}
  end
end
