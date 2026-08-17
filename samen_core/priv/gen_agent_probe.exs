# Anti-tautology probe for `mix samen.gen.agent` (ADR-047 A7).
#
# The load-bearing claim of the agent scaffolder is: "the generated agent + its AgentCase
# proof are correct-by-construction — they compile and pass." A test that only asserts the
# emitted files exist would be VACUOUS; this probe BINDS the claim to real correctness:
#
#   1. GENERATE — scaffold an agent (a valid opted-in tool) into a scratch scope under
#      samen_core; run its emitted AgentCase test — it MUST PASS (correct-by-construction).
#   2. SABOTAGE — rewrite the emitted definition's `tools:` to a NON-opted-in kind. Re-run
#      the emitted test — it MUST FAIL (the four-way intersection `resolve_definition/1`
#      assertion flips). This proves the scaffolded proof is non-vacuous.
#   3. REVERT — restore the definition; re-run — it MUST PASS again.
#
# SCHEMA: NONE. `mix samen.gen.agent` reserves no abbrev and writes no migration, so the
# committed abbrev registry is untouched — the `run_gen_probe` wrapper's SHA-256 byte-exact
# restore (T107) is satisfied trivially, and this probe additionally leaves ZERO file
# residue (the scratch scope is removed on every exit path, incl. a crash).
#
# Run:  cd samen_core && mix run priv/gen_agent_probe.exs
# Exit: 0 only if GENERATE passed, SABOTAGE flipped to fail, and REVERT recovered.

Mix.Task.run("compile")

alias Samen.Gen.Agent, as: Gen

suffix = System.unique_integer([:positive]) |> Integer.to_string() |> String.slice(-4, 4)
scope = "GenAgentProbe"
name = "Scout#{suffix}"
app_dir = File.cwd!()

IO.puts("== anti-tautology probe: mix samen.gen.agent correct-by-construction ==")
IO.puts("scope=#{scope} name=#{name}Agent")

spec =
  Gen.build_spec(app_dir: app_dir, scope: scope, name: name, tools: "search_records")

# The scratch scope dirs both lib/ and test/ land in — removed on EVERY exit path.
scratch_dirs = [
  Path.join([app_dir, "lib", Macro.underscore(spec.app_module), Macro.underscore(scope)]),
  Path.join([app_dir, "test", Macro.underscore(spec.app_module), Macro.underscore(scope)])
]

cleanup = fn -> Enum.each(scratch_dirs, &File.rm_rf!/1) end

halt = fn code, msg ->
  IO.puts(msg)
  cleanup.()
  System.halt(code)
end

run_test = fn test_path ->
  {out, code} =
    System.cmd("mix", ["test", Path.relative_to(test_path, app_dir)],
      cd: app_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )

  {code, out}
end

try do
  Gen.validate!(spec)
  [agent_path, test_path] = Gen.write!(spec)
  pristine = File.read!(agent_path)

  # --- 1. GENERATE: the scaffolded proof passes --------------------------------------
  {gen_code, gen_out} = run_test.(test_path)
  IO.puts("\ngenerate test exit: #{gen_code}  (MUST be 0 — correct-by-construction)")

  if gen_code != 0 do
    IO.puts(gen_out)
    halt.(1, "FAIL: the freshly-scaffolded agent proof did NOT pass — not a valid probe.")
  end

  # --- 2. SABOTAGE: a non-opted-in tool must flip the resolution assertion -----------
  anchor = ~s(tools: ["search_records"])

  unless String.contains?(pristine, anchor) do
    halt.(1, "FAIL: could not find the tools anchor to sabotage in #{agent_path}.")
  end

  File.write!(agent_path, String.replace(pristine, anchor, ~s(tools: ["not_a_real_tool"])))

  {sab_code, _sab_out} = run_test.(test_path)
  IO.puts("sabotaged test exit: #{sab_code}  (MUST be non-zero — the flip)")

  if sab_code == 0 do
    halt.(1, "FAIL: the emitted proof STILL PASSED with a non-opted-in tool — the " <>
             "correct-by-construction claim is a TAUTOLOGY.")
  end

  # --- 3. REVERT: restore the definition; the proof passes again ---------------------
  File.write!(agent_path, pristine)
  {rev_code, rev_out} = run_test.(test_path)
  IO.puts("reverted test exit: #{rev_code}  (MUST be 0 — green again)")

  if rev_code != 0 do
    IO.puts(rev_out)
    halt.(1, "FAIL: revert did not restore the scaffolded proof to green.")
  end

  IO.puts("\nRESULT: PROBE CONFIRMED — the scaffolded agent proof PASSED, FLIPPED under a")
  IO.puts("non-opted-in tool, and recovered on revert. `mix samen.gen.agent` is")
  IO.puts("correct-by-construction and its emitted proof is NON-vacuous.")

  cleanup.()
rescue
  e ->
    cleanup.()
    IO.puts("FAIL: probe crashed before completion: #{Exception.message(e)}")
    System.halt(1)
end
