defmodule Mix.Tasks.PiiReads.Verify do
  @moduledoc """
  Run the `pii_reads` AST verifier over one or more directories and exit
  non-zero (fail-closed) if any direct PII leak is found.

      mix pii_reads.verify corpus/leaks
      mix pii_reads.verify corpus/clean

  With no args, scans the whole `corpus/` tree (which INCLUDES seeded leaks,
  so it is expected to exit 1 — that is the red path).
  """
  use Mix.Task

  alias PiiReads.Harness

  @shortdoc "Fail-closed pii_reads AST verifier (exits 1 on a direct leak)"

  @impl Mix.Task
  def run(argv) do
    dirs =
      case argv do
        [] -> ["corpus"]
        list -> list
      end

    {code, findings} = Harness.check_dirs(dirs)

    findings
    |> Enum.filter(&(&1.kind in [:direct_leak, :parse_error]))
    |> Enum.each(fn f -> Mix.shell().error(Harness.format(f)) end)

    if code == 0 do
      Mix.shell().info("pii_reads: OK — no direct leaks in #{Enum.join(dirs, ", ")}")
    else
      Mix.shell().error("pii_reads: FAIL — #{leak_count(findings)} direct leak(s)")
    end

    # Fail closed: non-zero exit on any violation.
    System.halt(code)
  end

  defp leak_count(findings),
    do: Enum.count(findings, &(&1.kind in [:direct_leak, :parse_error]))
end
