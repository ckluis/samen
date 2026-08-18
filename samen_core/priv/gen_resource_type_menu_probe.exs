# ADR-036 H7 (T15 done-criterion 2) — the `mix samen.gen.resource --field-type` FULL TYPE
# MENU proof.
#
# Claim: EVERY entry of `Samen.Gen.FieldTypeMenu.menu/0` (string, money, percent, score,
# duration, priority, url, email, phone, address) scaffolds a resource whose `pii do` vault
# field carries that LOGICAL type, compiles clean (`--warnings-as-errors`), and passes its
# four generated G26 test files (policy matrix + masked PII, RBAC admin-gate, vault routing,
# catalog-parity) — AND the whole scratch app's full `ci.sh` (every verifier: catalog_parity,
# pii_classify, drift, vault_declared_parity, …) stays green with all ten resources mounted
# together.
#
# The run, end to end, in ONE automated pass:
#
#   1. GENERATE a fresh `--web` app (the flagship shape carries the Identity substrate the
#      G26 files target as the org anchor / RBAC subjects) into a project-local scratch dir,
#      with FRESH registry-safe abbrevs; compile + dump baselines.
#   2. `mix samen.gen.scope --scope Crm` once.
#   3. For EACH menu entry: `mix samen.gen.resource --scope Crm --resource <Type>Item --abbrev
#      <abc> --field-type <type>` (ten resources, ten distinct collision-free abbrevs,
#      one scope). No `--live` — the `--live` × non-default-`--field-type` LiveView-render
#      combination is a documented scope boundary (see the resource_show_live `render_secret/1`
#      defensive fix; not exercised end-to-end by this probe).
#   4. Compile `--warnings-as-errors`, re-dump `schema.dict.json`, run the app's FULL `ci.sh`
#      (must exit 0 — every verifier stays green with all ten resources mounted).
#   5. Focused-run the ten resources' 40 G26 test files directly (0 failures) — the literal
#      "passes its generated tests" done-criterion, not just "ci.sh happened to be green."
#
# REGISTRY SAFETY (mirrors gen_post_probe.exs): the committed abbrev registry is snapshotted
# BEFORE any reserve, and restored byte-exact on EVERY exit path (success, failure, crash).
#
# Run:  cd samen_core && mix run priv/gen_resource_type_menu_probe.exs
# Exit: 0 only if all ten menu-type resources compiled, the app's full ci.sh passed, and the
#       forty focused G26 test files passed.

t0 = System.monotonic_time(:millisecond)

Mix.Task.run("compile")

alias Samen.Gen.App, as: Gen
alias Samen.Gen.FieldTypeMenu

# --- unique, COLLISION-CHECKED app identity (the same de-flaked derivation gen_post_probe.exs
# uses) + NINE additional distinct resource abbrevs (one per remaining menu entry, beyond the
# one `app_identity/5` already derives for `extra_resource?: true`).
registry_loaded = Samen.AbbrevRegistry.load()

identity =
  Samen.Gen.ProbeAbbrev.app_identity(
    "Gentype",
    [web: true, api: true, target: "."],
    registry_loaded,
    System.unique_integer([:positive]),
    extra_resource?: true
  )

module = identity.module
prefix = identity.prefix
app_abbrev = identity.abbrev

menu = FieldTypeMenu.menu()

# Deterministically derive one distinct abbrev per menu entry, starting from the app's own
# `resource_abbrev` and advancing through the SAME collision-proof scan `ProbeAbbrev` uses —
# each newly-picked abbrev is added to `taken` before picking the next, so all ten (plus the
# app's own family) are mutually distinct AND registry-clear.
{abbrevs_by_type, _taken_final} =
  Enum.map_reduce(
    menu,
    MapSet.new([app_abbrev | Map.keys(registry_loaded)]),
    fn field_type, taken ->
      seed_candidate = Samen.Gen.ProbeAbbrev.next_clear_abbrev(identity.resource_abbrev, taken)
      abbrev = Samen.Gen.ProbeAbbrev.next_clear_abbrev(seed_candidate, taken)
      {{field_type, abbrev}, MapSet.put(taken, abbrev)}
    end
  )

abbrevs_by_type = Map.new(abbrevs_by_type)

samen_core_root = Gen.default_target() |> Path.join("samen_core")
scratch_parent = Path.join([samen_core_root, "..", "_gen_type_menu_scratch"]) |> Path.expand()

File.rm_rf!(scratch_parent)
File.mkdir_p!(scratch_parent)

# --- REGISTRY SAFETY: snapshot the committed registry FIRST ----------------------------
registry_path = Samen.AbbrevRegistry.path()
registry_pristine = File.read!(registry_path)

registry_scratch =
  Path.join(
    System.tmp_dir!(),
    "gen_type_menu_registry_pristine_#{System.system_time(:nanosecond)}.json"
  )

File.write!(registry_scratch, registry_pristine)

restored_clean? = fn ->
  File.write!(registry_path, File.read!(registry_scratch))
  File.read!(registry_path) == registry_pristine
end

cleanup = fn ->
  ok? = restored_clean?.()
  File.rm_rf!(scratch_parent)
  File.rm(registry_scratch)

  unless ok? do
    IO.puts(
      "FATAL: could not restore the committed abbrev registry byte-exact — MANUAL " <>
        "RECHECK of #{registry_path} REQUIRED."
    )

    System.halt(2)
  end
end

halt = fn code, msg ->
  IO.puts(msg)
  cleanup.()
  System.halt(code)
end

IO.puts("== ADR-036 H7 (T15) gen.resource --field-type TYPE MENU probe ==")
IO.puts("app=#{module} prefix=#{prefix} app_abbrev=#{app_abbrev}")
IO.puts("menu abbrevs: #{inspect(abbrevs_by_type)}")

mix = fn dir, args ->
  System.cmd("mix", args, cd: dir, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)
end

spec =
  Gen.build_spec(
    module: module,
    prefix: prefix,
    abbrev: app_abbrev,
    target: scratch_parent,
    web: true,
    api: true
  )

try do
  Gen.validate!(spec)
  Gen.reserve_abbrevs!(spec)
  Gen.write_app!(spec)
  Gen.compile_and_dump!(spec)

  app_dir = spec.app_dir
  IO.puts("H7: generated the base --web app (#{module}).")

  {scope_out, scope_code} = mix.(app_dir, ["samen.gen.scope", "--scope", "Crm"])

  if scope_code != 0 do
    IO.puts(scope_out)
    halt.(1, "FAIL: `mix samen.gen.scope --scope Crm` did not succeed.")
  end

  IO.puts("H7: gen.scope emitted #{module}.Crm.")

  # --- gen.resource --field-type, ONE PER MENU ENTRY -------------------------------------
  four_files_for = fn resource_name ->
    stem = "crm_#{Macro.underscore(resource_name)}"

    [
      "test/#{stem}_policy_matrix_test.exs",
      "test/#{stem}_rbac_red_path_test.exs",
      "test/#{stem}_vault_routing_test.exs",
      "test/#{stem}_catalog_parity_red_path_test.exs"
    ]
  end

  all_four_files =
    Enum.flat_map(menu, fn field_type ->
      resource_name = "#{Macro.camelize(field_type)}Item"
      abbrev = Map.fetch!(abbrevs_by_type, field_type)

      {res_out, res_code} =
        mix.(app_dir, [
          "samen.gen.resource",
          "--scope",
          "Crm",
          "--resource",
          resource_name,
          "--abbrev",
          abbrev,
          "--field-type",
          field_type
        ])

      if res_code != 0 do
        IO.puts(res_out)
        halt.(1, "FAIL: `mix samen.gen.resource --field-type #{field_type}` did not succeed.")
      end

      resource_file =
        Path.join(app_dir, "lib/#{spec.otp_app}/crm/#{Macro.underscore(resource_name)}.ex")

      unless File.exists?(resource_file) do
        halt.(1, "FAIL: gen.resource --field-type #{field_type} did not emit #{resource_file}.")
      end

      expected_type = FieldTypeMenu.ash_type(field_type)

      unless File.read!(resource_file) =~
               "pii_attribute(:secret, #{expected_type}, vault: :pii_secret)" do
        halt.(
          1,
          "FAIL: #{resource_file} does not declare pii_attribute(:secret, #{expected_type}, " <>
            "vault: :pii_secret) for --field-type #{field_type}."
        )
      end

      files = four_files_for.(resource_name)

      for f <- files do
        unless File.exists?(Path.join(app_dir, f)) do
          halt.(1, "FAIL: gen.resource --field-type #{field_type} did not emit #{f}.")
        end
      end

      IO.puts(
        "H7: gen.resource --field-type #{field_type} emitted #{module}.Crm.#{resource_name} " <>
          "(abbrev #{abbrev}, type #{expected_type})."
      )

      files
    end)

  # --- compile + re-dump the drift baseline + the WHOLE app's full ci.sh -----------------
  {c_out, c_code} = mix.(app_dir, ["compile", "--warnings-as-errors"])

  if c_code != 0 do
    IO.puts(c_out)
    halt.(1, "FAIL: the app did not compile after ten --field-type resources.")
  end

  IO.puts("H7: all ten menu-type resources compiled clean (--warnings-as-errors).")

  {_dump_out, dump_code} = mix.(app_dir, ["samen.catalog.dump", "--output", "schema.dict.json"])

  if dump_code != 0 do
    halt.(1, "FAIL: could not re-dump schema.dict.json after adding ten resources.")
  end

  {gate_out, gate_code} =
    System.cmd("bash", ["ci.sh"], cd: app_dir, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

  IO.puts("\nfull ci.sh exit (ten --field-type resources mounted): #{gate_code}  (MUST be 0)")

  if gate_code != 0 do
    IO.puts(gate_out)
    halt.(1, "FAIL: ci.sh did NOT pass with all ten --field-type resources — not correct-by-construction.")
  end

  # --- the literal done-criterion: a FOCUSED run of the forty G26 files, 0 failures ------
  {t_out, t_code} = mix.(app_dir, ["test" | all_four_files])

  if t_code != 0 do
    IO.puts(t_out)
    halt.(1, "FAIL: the forty generated G26 test files (ten resources) did not all pass on a focused run.")
  end

  IO.puts("H7: all forty G26 test files (ten menu-type resources) PASSED on a focused run.")

  elapsed = System.monotonic_time(:millisecond) - t0

  IO.puts("\nRESULT: TYPE MENU PROBE CONFIRMED (ADR-036 H7 / T15 done-criterion 2) —")

  IO.puts(
    "`mix samen.gen.resource --field-type` scaffolded all ten menu entries " <>
      "(#{Enum.join(menu, ", ")}) into #{module}.Crm, each compiling clean and passing its " <>
      "four generated G26 files, with the whole app's full ci.sh green across all ten. " <>
      "Total probe runtime: #{Float.round(elapsed / 1000, 1)}s. Zero residue."
  )

  cleanup.()
rescue
  e ->
    cleanup.()
    IO.puts("FAIL: gen.resource type-menu probe crashed before completion: #{Exception.message(e)}")
    IO.puts(Exception.format(:error, e, __STACKTRACE__))
    System.halt(1)
end
