defmodule SamenCore.VerifyApiContractTaskTest do
  @moduledoc """
  X9 — `mix samen.verify.api_contract` non-emptiness floor (luminary pre-merge).

  ## The defect this pins

  The task could go silently vacuous: `Snapshot.resource_entry/1` rescues every
  per-resource introspection failure into absence, and a mis-keyed `:ash_domains`
  yields `[]` outright. Before the floor, `--update` wrote an EMPTY snapshot with
  no complaint, and an empty live contract diffed against that empty snapshot
  printed "OK — no structural breaks found." forever — a contract gate that pins
  nothing and can never flip.

  ## The floor

  The task now FAILS CLOSED (exit 1) whenever the LIVE contract discovers zero
  AshJsonApi resources — before writing (`--update`) AND before diffing. Same
  fail-closed shape as `vault_declared_parity` / `oban_queues` /
  `erasure_completeness`.

  ## Why this runs in samen_core

  samen_core's own test-env domains expose ZERO AshJsonApi resources (the
  JSON:API surface lives in the hosts), so a bare run here IS the empty-discovery
  condition — deterministic, no fixture sabotage needed. The POSITIVE control
  (a non-empty live contract passes the floor and diffs green) is demo:
  `demo/test/api_contract_verifier_test.exs` asserts the demo contract is
  non-empty, and demo's ci.sh step 16 runs the full task green against the
  committed 4-resource snapshot.

  ## Exit-code layer

  Subprocess (`System.cmd/3`) because the task exits via `:erlang.halt/1` — the
  same pattern as the vault_declared_parity and pii_reads floor tests.
  """

  use ExUnit.Case, async: false

  @project_dir Path.expand("../", __DIR__)

  describe "RED PATH: fail-closed on empty contract discovery (X9)" do
    @tag :exit_code
    test "mix task exits 1 in --update mode and REFUSES to write an empty snapshot" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "samen_api_contract_floor_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(tmp) end)

      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.api_contract", "--version", "v1", "--update", "--snapshot", tmp],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit 1 on empty contract discovery in --update mode (a vacuous " <>
               "snapshot must never be written), got #{exit_code}.\nOutput: #{output}"

      assert output =~ "ZERO AshJsonApi resources",
             "Expected the fail-closed diagnostic, got: #{output}"

      refute File.exists?(tmp),
             "--update WROTE an empty snapshot despite the floor — every future diff " <>
               "would green vacuously (empty vs empty)."
    end

    @tag :exit_code
    test "mix task exits 1 in diff mode (empty-vs-empty must not print OK)" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "samen_api_contract_empty_#{System.unique_integer([:positive])}.json"
        )

      # A committed-empty snapshot — the exact artifact a pre-floor `--update`
      # run would have produced.
      File.write!(tmp, ~s({\n  "resources": [],\n  "version": "v1"\n}\n))
      on_exit(fn -> File.rm(tmp) end)

      {output, exit_code} =
        System.cmd(
          "mix",
          ["samen.verify.api_contract", "--version", "v1", "--snapshot", tmp],
          cd: @project_dir,
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      assert exit_code == 1,
             "Expected exit 1 on empty contract discovery in diff mode, got " <>
               "#{exit_code}.\nOutput: #{output}"

      assert output =~ "ZERO AshJsonApi resources",
             "Expected the fail-closed diagnostic, got: #{output}"

      refute output =~ "OK — no structural breaks found",
             "The vacuous green banner printed on an empty-vs-empty diff: #{output}"
    end
  end
end
