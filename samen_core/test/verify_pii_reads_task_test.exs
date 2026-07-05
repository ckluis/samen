defmodule SamenCore.VerifyPiiReadsTaskTest do
  @moduledoc """
  Exit-code layer for `mix samen.verify.pii_reads` (T1.8b) — the only way to
  observe `:erlang.halt/1` without terminating the test VM is a child OS process
  (`System.cmd/3`), the same convention as the C1/C2 verifier task tests.

  The task builds its registry from the configured `:ash_domains`
  (`SamenCore.Support.Clinical` → Patient), so the task-corpus fixtures use PII
  names Patient declares (`:full_name`) — no reliance on the RevealDomain fixture
  (which is not in the configured domains). The task-clean corpus is
  RevealDomain-independent (declarations + non-pii logging only).

  ## Anti-tautology probe (HARD RULE §2)

  Run in a scratch copy: forcing `Samen.PiiReads.Harness.exit_code/1` to always
  return 0 flipped the leak-corpus exit-code test to FAIL (observed exit 0,
  expected 1) while the diagnostic text still printed — proving the assertion
  checks the real process exit status. Result recorded in reports/T1.8b.md.
  """
  use ExUnit.Case, async: false

  @project_dir Path.expand("../", __DIR__)

  @tag :exit_code
  test "mix task exits 1 when a direct leak is present (fail closed)" do
    {output, exit_code} = run_task("test/pii_reads_corpus/task_leak")

    assert exit_code == 1,
           "Expected exit 1 for a leak corpus, got #{exit_code}.\nOutput: #{output}"

    assert output =~ "PII LEAK", "Expected a PII LEAK diagnostic, got: #{output}"
    assert output =~ "full_name", "Expected the leaked pii name in output, got: #{output}"
  end

  @tag :exit_code
  test "mix task exits 0 on a clean corpus (declarations + non-pii)" do
    {output, exit_code} = run_task("test/pii_reads_corpus/task_clean")

    assert exit_code == 0,
           "Expected exit 0 for a clean corpus, got #{exit_code}.\nOutput: #{output}"

    assert output =~ "OK", "Expected an OK banner, got: #{output}"
  end

  defp run_task(source_dir) do
    System.cmd(
      "mix",
      ["samen.verify.pii_reads", "--source-dirs", source_dir],
      cd: @project_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
