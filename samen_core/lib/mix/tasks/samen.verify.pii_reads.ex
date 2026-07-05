defmodule Mix.Tasks.Samen.Verify.PiiReads do
  @shortdoc "Fail build on any vault-declared PII value flowing to a sink outside :reveal."

  @moduledoc """
  `mix samen.verify.pii_reads` — verifier C3 (plan §C, T1.8b; Gate-0 fix task #6).

  ## What it checks

  A **direct** flow of a vault-declared PII value into a `Logger` / span / event
  sink call that sits **outside** a declared `:reveal` action is a violation. This
  is a dataflow *match* over Elixir source (NOT a sound taint proof — doc §runs 4a);
  the laundered path (pii passed through a helper first) is caught by the J2 sink
  schema allow-list (Phase 2), and is a documented expected-miss here.

  Keys on the **declaration**, never on a `pii_` column prefix:

    * the PII attribute set comes from `Samen.Pii.Info` introspection over every
      resource's `pii do … end` block (logical AND storage names) — a composite
      field like `pat_full_name` carries no `pii_` prefix but IS vault-routed;

    * reveal-scope suppression keys on the REAL Ash `reveal :action` marker
      (`Samen.Pii.Info.reveal_actions/1`), NOT a lexical `reveal`-name prefix. A
      `def reveal_report/1` — or an `action :reveal_report` never declared
      `reveal :reveal_report` — is NOT a reveal boundary; its sinks are flagged.

  Aliased sink modules (`alias Logger, as: L` then `L.info(...)`) are resolved
  from module context and treated as sinks.

  ## What it scans

  Source files under `lib/` for the current mix project (configurable via
  `--source-dirs`). Declaration blocks (`pii do … end`) are structurally skipped.

  ## Exit code (fail-closed)

  Exits 0 when no `:direct_leak` and no `:parse_error` finding is present, 1
  otherwise (via `:erlang.halt/1`, so no cleanup hook can swallow the code).
  Unparseable source is a `:parse_error` (never silently skipped).
  `:laundered_hint` advisories are printed but NEVER affect the exit code.

  **Empty-registry guard (Gate-1 F1):** if the built PII registry contains zero
  PII attributes — the default when a host app has not configured its
  `ash_domains` (or configured them under a key the registry does not read) — the
  taint set is empty and EVERY leak would pass. That is a fail-OPEN safety defect,
  so the task **exits 1 with a config diagnostic** rather than printing a
  misleading "OK". A vacuous check must never pass. Domains are discovered from
  the host app's `ash_domains` (the standard Ash convention C1/C4 use), with the
  legacy `:samen_core, :ash_domains` key honored only as a fallback alias.

  ## Usage

      mix samen.verify.pii_reads
      mix samen.verify.pii_reads --source-dirs lib
  """

  use Mix.Task

  alias Samen.PiiReads
  alias Samen.PiiReads.{Harness, Registry}

  @task_name "samen.verify.pii_reads"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [source_dirs: [:string, :keep]])

    # app.start compiles + starts the app so resource modules are loaded and the
    # registry can introspect their `pii do` blocks.
    Mix.Task.run("app.start")

    registry = Registry.build()
    halt_if_registry_empty!(registry)

    source_dirs = resolve_source_dirs(opts)
    findings = scan(source_dirs, registry)

    hints = Enum.filter(findings, &(&1.kind == :laundered_hint))
    print_hints(hints)

    violations =
      findings
      |> Harness.failing()
      |> Enum.map(&Harness.format/1)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Scan `source_dirs` with `registry` and return every finding (direct leaks,
  parse errors, and laundered hints). Separated from `run/1` so tests can call it
  without triggering `:erlang.halt/1`.
  """
  @spec scan([String.t()], Registry.t()) :: [map()]
  def scan(source_dirs \\ ["lib"], registry \\ Registry.build()) do
    source_dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      {:ok, findings} = PiiReads.scan_dir(dir, registry)
      findings
    end)
  end

  # ---------------------------------------------------------------------------

  # Fail-closed guard (Gate-1 F1): an empty PII registry means the taint set is
  # empty, so EVERY leak would pass — a vacuous check. That is a fail-OPEN safety
  # defect, so we refuse to run and exit 1 with a config diagnostic instead of
  # printing a misleading "OK". This never silently passes.
  defp halt_if_registry_empty!(%Registry{pii_attributes: pii_attributes}) do
    if MapSet.size(pii_attributes) == 0 do
      IO.puts("")

      IO.puts(
        "FAIL: #{@task_name} refusing to run against an EMPTY PII registry " <>
          "(0 PII attributes discovered)."
      )

      IO.puts("")

      IO.puts(
        "  No PII resources were discovered. Configure your Ash domains the " <>
          "standard way:"
      )

      IO.puts("")
      IO.puts("      config #{inspect(Mix.Project.config()[:app])}, ash_domains: [MyApp.MyDomain]")
      IO.puts("")

      IO.puts(
        "  A vacuous PII check would pass every leak, so this is a fail-closed " <>
          "refusal, not a pass."
      )

      IO.puts("")
      :erlang.halt(1)
    end

    :ok
  end

  defp resolve_source_dirs(opts) do
    case Keyword.get_values(opts, :source_dirs) do
      [] -> ["lib"]
      dirs -> dirs
    end
  end

  defp print_hints([]), do: :ok

  defp print_hints(hints) do
    IO.puts("")
    IO.puts("#{@task_name}: #{length(hints)} laundered-flow advisory(ies) (NOT failures):")

    Enum.each(hints, fn h -> IO.puts("  · #{Harness.format(h)}") end)
  end
end
