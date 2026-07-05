defmodule Samen.Verifier do
  @moduledoc """
  Harness for Samen verifier mix tasks.

  Verifiers follow a consistent three-step pattern:
    1. Introspect — gather facts from code and/or the running DB.
    2. Check — compute violations.
    3. Report — print human-readable diagnostics, then exit(1) if any violations.

  This module provides shared helpers for the pattern. Each concrete verifier
  (e.g. `Mix.Tasks.Samen.Verify.CatalogParity`) calls `halt_if_violations/2` with
  a task name and list of violations; the harness prints them and exits non-zero if
  the list is non-empty.

  ## Exit behaviour (fail-closed guarantee)

  `halt_if_violations/2` calls `:erlang.halt(1)` directly (not `System.stop/1`)
  so the process exits immediately after printing diagnostics — no cleanup hook
  can swallow the non-zero code. In the test harness the tests capture this by
  calling the task via `System.cmd/3` in a child OS process rather than calling
  the task function directly, which gives a true end-to-end exit-code assertion.
  """

  @doc """
  Print violations and exit(1) if there are any; otherwise print a pass banner.

  `task_name` is used only in the banner (e.g. `"samen.verify.catalog_parity"`).
  `violations` is a list of human-readable strings naming the offending item.
  """
  def halt_if_violations(task_name, violations) do
    if violations == [] do
      IO.puts("#{task_name}: OK — no violations found.")
    else
      IO.puts("")
      IO.puts("FAIL: #{task_name} found #{length(violations)} violation(s):")

      Enum.each(violations, fn v ->
        IO.puts("  • #{v}")
      end)

      IO.puts("")
      :erlang.halt(1)
    end
  end
end
