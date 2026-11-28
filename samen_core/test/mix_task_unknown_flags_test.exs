defmodule Samen.MixTaskUnknownFlagsTest do
  @moduledoc """
  The generated `AGENTS.md` tells an agent that every generator refuses unknown flags. A guessed or typo'd flag on
  a verifier or a generator must never be dropped silently: the verifier would check something other than what was
  asked and still print OK, and a generator would write something other than what was asked.

  Every task below parses its options through `Samen.Gen.Args.parse!/3` (the helper `samen.gen.app|resource|scope|agent`
  and `samen.abbrev.reserve` use), so a refused run raises `Mix.Error` naming the flag BEFORE the task does anything else.

  Three families, each proven through the task's own `run/1`:

    * generators (`samen.gen.indexes`, `reveal_requests`, `api_key_digest_unique`, `csat_token_digest_unique`, `api_key_scopes`)
    * verifiers (`samen.verify.*` that take flags)
    * the other flag-taking tasks (`samen.audit.freeform_projection`, `samen.ai.smoke`)

  Each family also has a positive control in a child OS process (the tasks exit through `:erlang.halt/1`): the same
  task with VALID flags is not refused as an unknown flag, so the strictness is not "refuse everything".

  The eight tasks that already refuse through `OptionParser.parse!/2` (`migrations`, `read_scope`, `pii_classify`,
  `never_read_current`, `catalog_meaning`, `no_plaintext_pii`, `pii_reads`, `catalog.dump`) are covered by their own tests.
  """
  use ExUnit.Case, async: false

  @project_dir Path.expand("../", __DIR__)

  @generators ~w(samen.gen.indexes samen.gen.reveal_requests samen.gen.api_key_digest_unique samen.gen.csat_token_digest_unique samen.gen.api_key_scopes)
  @verifiers ~w(samen.verify.fleet_wire samen.verify.signals_no_pii samen.verify.vault_declared_parity
                samen.verify.agent_coverage samen.verify.catalog_parity samen.verify.metric_labels
                samen.verify.vault_token_binding samen.verify.tnt_catalog samen.verify.no_pii_columns
                samen.verify.aggregate_privacy samen.verify.indexes samen.verify.prefixes
                samen.verify.no_pan_columns samen.verify.same_org_fk samen.verify.ai_prompt_masking
                samen.verify.tnt_boundary samen.verify.api_contract)
  @others ~w(samen.audit.freeform_projection samen.ai.smoke)

  defp refuses!(task, argv) do
    mod = Mix.Task.get!(task)

    err =
      assert_raise Mix.Error, fn ->
        ExUnit.CaptureIO.capture_io(fn -> mod.run(argv) end)
      end

    assert err.message =~ "mix #{task}: unknown flag --no-such-flag"
    assert err.message =~ "Nothing was written or reserved. Valid switches:"
    err
  end

  describe "RED PATH: an unknown flag is refused through the task's run/1" do
    test "every generator refuses an unknown flag" do
      out = scratch_dir()
      for task <- @generators, do: refuses!(task, ["--out", out, "--no-such-flag"])
    end

    test "a positional argument is refused by a generator too" do
      err = assert_raise Mix.Error, fn -> Mix.Tasks.Samen.Gen.Indexes.run(["--out", scratch_dir(), "stray"]) end
      assert err.message =~ ~s(unexpected positional argument "stray")
    end

    test "every verifier that takes flags refuses an unknown flag" do
      for task <- @verifiers, do: refuses!(task, ["--no-such-flag"])
    end

    test "a misspelled verifier flag is refused and names the valid ones" do
      err = refuses_flag!("samen.verify.same_org_fk", ["--domian", "X"], "--domian")
      assert err.message =~ "--domain"
    end

    test "the audit and smoke tasks refuse an unknown flag" do
      for task <- @others, do: refuses!(task, ["--no-such-flag"])
    end
  end

  describe "positive control: valid flags are not refused (child process, real exit code)" do
    @tag :exit_code
    test "generator family: samen.gen.indexes with valid flags is not refused as an unknown flag" do
      out = scratch_dir()

      {output, _code} = mix(["samen.gen.indexes", "--out", out, "--timestamp", "20261114100000", "--domain", "Samen.NoSuchDomain"])
      refute output =~ "unknown flag"

      {output, code} = mix(["samen.gen.indexes", "--out", out, "--no-such-flag"])
      assert code != 0
      assert output =~ "mix samen.gen.indexes: unknown flag --no-such-flag"
    end

    @tag :exit_code
    test "verifier family: samen.verify.prefixes with a valid flag is not refused as an unknown flag" do
      {output, _code} = mix(["samen.verify.prefixes", "--repo", "Samen.NoSuchRepo"])
      refute output =~ "unknown flag"

      {output, code} = mix(["samen.verify.prefixes", "--no-such-flag"])
      assert code != 0
      assert output =~ "mix samen.verify.prefixes: unknown flag --no-such-flag"
    end

    @tag :exit_code
    test "other family: samen.ai.smoke with a valid flag runs and exits 0; an unknown flag exits non-zero" do
      {output, code} = mix(["samen.ai.smoke", "--prompt", "hello"])
      refute output =~ "unknown flag"
      assert code == 0, output

      {output, code} = mix(["samen.ai.smoke", "--no-such-flag"])
      assert code != 0
      assert output =~ "mix samen.ai.smoke: unknown flag --no-such-flag"
    end
  end

  # A generator that failed to refuse would write its migration here, never into the app's own migrations.
  defp scratch_dir do
    dir = Path.join(System.tmp_dir!(), "unknown_flags_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp refuses_flag!(task, argv, flag) do
    mod = Mix.Task.get!(task)

    err =
      assert_raise Mix.Error, fn ->
        ExUnit.CaptureIO.capture_io(fn -> mod.run(argv) end)
      end

    assert err.message =~ "mix #{task}: unknown flag #{flag}"
    err
  end

  defp mix(args) do
    System.cmd("mix", args, cd: @project_dir, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)
  end
end
