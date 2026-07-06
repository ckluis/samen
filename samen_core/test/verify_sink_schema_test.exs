defmodule Mix.Tasks.Samen.Verify.SinkSchemaTest do
  @moduledoc """
  T2.7 — end-to-end exit-code tests for the J2 build check `mix samen.verify.sink_schema`.

  The pure-function logic (`Samen.WideEvent.Schema.violations/1`) is red-path
  tested in `wide_event_test.exs`; this file proves the fail-closed behaviour at
  the PROCESS boundary (`:erlang.halt/1`) — the only way to observe the real exit
  code — via `System.cmd/3` in a child OS process.
  """
  use ExUnit.Case, async: false

  @project_dir File.cwd!()

  @tag :exit_code
  test "exits 0 on the clean (real) schema" do
    {output, exit_code} =
      System.cmd("mix", ["samen.verify.sink_schema"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert exit_code == 0, "Expected exit 0 on the clean schema, got #{exit_code}.\nOutput: #{output}"
    assert output =~ "OK", "Expected OK banner, got: #{output}"
  end

  @tag :exit_code
  test "RED PATH: exits 1 with a seeded string-typed field (the name-carrier)" do
    {output, exit_code} =
      System.cmd("mix", ["samen.verify.sink_schema"],
        cd: @project_dir,
        env: [
          {"MIX_ENV", "test"},
          {"SAMEN_SINK_SCHEMA_INJECT_STRING_FIELD", "debug_actor_name"}
        ],
        stderr_to_stdout: true
      )

    assert exit_code == 1,
           "Expected exit 1 on a seeded string field, got #{exit_code}.\nOutput: #{output}"

    assert output =~ "debug_actor_name", "Expected the offending field in output, got: #{output}"
    assert output =~ "FORBIDDEN", "Expected the FORBIDDEN diagnostic, got: #{output}"
  end
end
