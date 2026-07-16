# Anti-tautology probe for the T6.4 GENERATED-GATE-PASSES assertion.
#
# The load-bearing claim of `mix samen.gen.app` is: "the generated app passes its own
# verifier gate (correct-by-construction)." A test that only asserts `ci.sh exits 0` on a
# freshly-generated app could be VACUOUS — if the gate were toothless, ANY app (even a
# broken one) would pass, and the green would prove nothing.
#
# This probe proves the assertion is NON-vacuous by BINDING it to real correctness:
#
#   1. BASELINE — generate an app into a project-local scratch dir; run its ci.sh; the gate
#      must PASS (exit 0). This is the correct-by-construction claim.
#   2. SABOTAGE — inject a forbidden leak into the GENERATED app: add a `pii_`-shaped column
#      to the token-blind aggregate table (the exact thing the C7 `no_pii_columns` gate step
#      forbids). Re-run ci.sh; the gate must now FAIL (non-zero). This is the FLIP.
#   3. REVERT — restore the generated app to its pristine state; run ci.sh again; the gate
#      must PASS again. This is the recovery.
#
# If the sabotaged app STILL passes, the gate is a tautology and this probe halts non-zero.
#
# Scratch dir: <samen_core>/../_gen_probe_scratch/<app> (project-local, removed on exit). It
# is a sibling of samen_core so the generated app's `{:samen_core, path: "../samen_core"}`
# resolves. It is NEVER added to the root ci.sh.
#
# Run:  cd samen_core && mix run priv/gen_app_gate_probe.exs
# Exit: 0 only if baseline PASSED, sabotage FLIPPED to fail, and revert recovered.

Mix.Task.run("compile")

alias Samen.Gen.App, as: Gen

# --- unique, collision-proof app identity (fresh abbrevs each run) ---------------------
# First prefix letter "g": the g* abbrev space is unowned in the committed registry, so the
# billing family (`g<l1>*`), aggregate (`g<l1>a`), and the resource abbrev all stay inside
# it. The resource abbrev's SECOND letter is `z` (mirrors the web/flagship probes' `hz*`/
# `jz*`) so it never collides with the derived billing family — a fixed leading letter that
# escapes the `g` space (the old `p<l1><l2>` form) could land on pawchart's `pb*` family.
suffix = System.unique_integer([:positive]) |> Integer.to_string() |> String.slice(-2, 2)
letters = for <<c <- suffix>>, do: rem(c - ?0, 26) + ?a
[l1, l2] = letters
prefix = <<?g, l1>>
resource_abbrev = <<?g, ?z, l2>>
module = "Genprobe" <> String.upcase(<<l1, l2>>)

samen_core_root = Gen.default_target() |> Path.join("samen_core")
scratch_parent = Path.join([samen_core_root, "..", "_gen_probe_scratch"]) |> Path.expand()

File.rm_rf!(scratch_parent)
File.mkdir_p!(scratch_parent)

registry_path = Samen.AbbrevRegistry.path()
registry_backup = File.read!(registry_path)

cleanup = fn ->
  # Restore the committed registry (the probe reserved app abbrevs into it) and remove the
  # scratch app. The probe must leave NO trace.
  File.write!(registry_path, registry_backup)
  File.rm_rf!(scratch_parent)
end

halt = fn code, msg ->
  IO.puts(msg)
  cleanup.()
  System.halt(code)
end

IO.puts("== anti-tautology probe: mix samen.gen.app generated-gate-passes ==")
IO.puts("app module=#{module} prefix=#{prefix} abbrev=#{resource_abbrev}")

# WS-D D2: the generator's default is now `--web` (ADR-022). THIS probe stays the
# HEADLESS probe (AC-G4-10: `--headless` reproduces the original 26-file data-only output
# and its gate still flips under sabotage). The web/boot probe is priv/gen_app_web_probe.exs.
spec =
  Gen.build_spec(
    module: module,
    prefix: prefix,
    abbrev: resource_abbrev,
    target: scratch_parent,
    web: false
  )

try do
  Gen.validate!(spec)
rescue
  e -> halt.(1, "FAIL: generated spec did not validate: #{Exception.message(e)}")
end

# From here on the registry has been mutated and files written — ANY failure (including a
# raised exception from compile_and_dump!) must still clean up. Wrap the whole flow.
try do
  Gen.reserve_abbrevs!(spec)
  Gen.write_app!(spec)
  Gen.compile_and_dump!(spec)

  app_dir = spec.app_dir

  run_gate = fn ->
  {out, code} =
    System.cmd("bash", ["ci.sh"],
      cd: app_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )

  {code, out}
end

# --- 1. BASELINE: the generated app passes its own gate --------------------------------
{baseline_code, baseline_out} = run_gate.()
IO.puts("\nbaseline gate exit: #{baseline_code}  (MUST be 0 — correct-by-construction)")

if baseline_code != 0 do
  IO.puts(baseline_out)
  halt.(1, "FAIL: freshly-generated app did NOT pass its gate — not a valid probe.")
end

# --- 2. SABOTAGE: add a forbidden pii_ column to the token-blind aggregate table -------
migration = Path.join(app_dir, "priv/repo/migrations/20260709100000_app_resources.exs")
pristine = File.read!(migration)

anchor = "add(:#{spec.agg_abbrev}_segment, :text, null: false)"

unless String.contains?(pristine, anchor) do
  halt.(1, "FAIL: could not find the aggregate-table anchor to sabotage in #{migration}.")
end

sabotaged_migration =
  String.replace(
    pristine,
    anchor,
    anchor <> "\n      add(:pii_#{spec.agg_abbrev}_leak, :text)"
  )

File.write!(migration, sabotaged_migration)

# The schema.dict drift check would fail first on a plain add; a `pii_` column on an
# aggregate table is exactly the C7 `no_pii_columns` violation. Either way the gate MUST
# fail — the point is the flip. Re-dump the dict so we test the C7 step, not merely drift.
{_dump_out, _dump_code} =
  System.cmd("mix", ["samen.catalog.dump", "--output", "schema.dict.json"],
    cd: app_dir,
    env: [{"MIX_ENV", "test"}],
    stderr_to_stdout: true
  )

{sabotaged_code, _sabotaged_out} = run_gate.()
IO.puts("sabotaged gate exit: #{sabotaged_code}  (MUST be non-zero — the flip)")

if sabotaged_code == 0 do
  halt.(1, "FAIL: gate STILL PASSED with a pii_ column on the aggregate plane — the " <>
             "generated-gate-passes claim is a TAUTOLOGY.")
end

# --- 3. REVERT: restore the pristine app; gate passes again ----------------------------
File.write!(migration, pristine)

{_redump_out, _redump_code} =
  System.cmd("mix", ["samen.catalog.dump", "--output", "schema.dict.json"],
    cd: app_dir,
    env: [{"MIX_ENV", "test"}],
    stderr_to_stdout: true
  )

{reverted_code, reverted_out} = run_gate.()
IO.puts("reverted gate exit: #{reverted_code}  (MUST be 0 — green again)")

if reverted_code != 0 do
  IO.puts(reverted_out)
  halt.(1, "FAIL: revert did not restore the gate to green.")
end

  IO.puts("\nRESULT: PROBE CONFIRMED — the generated gate PASSED on a correct app, FLIPPED to")
  IO.puts("FAIL under an injected pii_-on-aggregate leak, and recovered on revert. The")
  IO.puts("'generated app passes its own gate' assertion is NON-vacuous.")

  cleanup.()
rescue
  e ->
    cleanup.()
    IO.puts("FAIL: probe crashed before completion: #{Exception.message(e)}")
    System.halt(1)
end
