# WS-D D7a — the POST-APP GENERATOR proof (AC-G4-7 / AC-G26-1 / AC-G26-3).
#
# Claim: `mix samen.gen.scope` + `mix samen.gen.resource` scaffold the SECOND scope +
# resource of an app correct-by-construction — the resource compiles, catalogs, reserves
# its abbrev, and the FOUR emitted G26 red-path test files pass — with ZERO hand-edits;
# and the emitted red paths are NON-VACUOUS (a sabotage of a red-path's mechanism flips it).
#
# The run, end to end, in ONE automated pass:
#
#   1. GENERATE a fresh `--web --api --seeds --observability` app (the flagship shape — it
#      carries the `Operator.{Org,User,Membership}` Identity substrate the four G26 files
#      target as the org anchor / RBAC subjects) into a project-local scratch dir, with
#      FRESH registry-safe abbrevs; compile + dump baselines (Gen.compile_and_dump!/1).
#   2. `mix samen.gen.scope --scope Crm` — emits the empty authored domain + registers it
#      in BOTH :ash_domains lists.
#   3. `mix samen.gen.resource --scope Crm --resource Widget --abbrev <abc>` — emits the
#      Tier-0 resource + its migration + the abbrev reservation + the FOUR G26 test files
#      + the per-resource anti-tautology probe, wired into the Crm domain.
#   4. Re-dump `schema.dict.json` (the drift baseline now includes the new table — the same
#      commit-the-baseline step a human does), then run the app's FULL `ci.sh`: it migrates
#      (picks up the new migration), runs the WHOLE verifier gate (catalog_parity /
#      pii_classify / drift / etc. STILL green with the new resource), AND runs the four
#      emitted red-path files. It must PASS (exit 0) — correct-by-construction.
#   5. Run the emitted per-resource anti-tautology probe standalone — it must confirm the
#      catalog-parity red is non-vacuous (flips when the catalogued column is uncatalogued).
#   6. SABOTAGE a red-path MECHANISM and prove the emitted test FLIPS: remove the
#      `RoleAtLeast` admin gate from the generated resource → the RBAC `admin_gate_red_path`
#      (a member CANNOT create) MUST fail (a member now CAN create). Revert byte-exact →
#      the four tests pass again. A red path whose sabotage cannot flip is a tautology.
#
# Zero scratch residue: the scratch app is removed and the committed abbrev registry is
# restored BYTE-EXACT from a scratch/tmp copy on every exit path (success, failure, crash);
# the restore is ASSERTED byte-equal.
#
# REGISTRY SAFETY (the standing carry): this probe NEVER treats the committed
# samen_core/priv/abbrev_registry.json as its own working copy. Pristine bytes are
# snapshotted to a scratch/tmp file FIRST; the reserves write the app + resource abbrevs
# into the physical registry (unavoidable — the generated code reads
# `:code.priv_dir(:samen_core)` at ITS compile time), and the physical file is restored
# from the scratch copy on exit.
#
# T107 (interrupt hardening): both the scratch app dir and the registry snapshot are now
# created via real OS `mktemp`/`mktemp -d` (unique-per-run, collision-immune by construction
# — a pre-planted stray file with a colliding-shaped name cannot break the run, unlike the
# old nanosecond-timestamp naming). A `:sigterm` trap (`System.trap_signal/3`) runs `cleanup.()`
# for defense-in-depth when this probe is invoked directly (outside ci.sh). NOTE: `:sigint` is
# NOT trappable inside the BEAM (`System.trap_signal/3` has no :sigint clause) — the
# AUTHORITATIVE interrupt backstop for both SIGINT and SIGTERM is the OS-level snapshot+trap
# wrapper in root `ci.sh` (`run_gen_probe`), which restores the registry byte-exact regardless
# of whether this process gets a chance to run its own cleanup at all.
#
# Run:  cd samen_core && mix run priv/gen_post_probe.exs
# Exit: 0 only if the post-app generators scaffolded a second scope+resource that passed
#       its full ci.sh with the four G26 files green, the anti-tautology probe confirmed,
#       and a red-path-mechanism sabotage flipped a red path and reverted byte-exact.

t0 = System.monotonic_time(:millisecond)

Mix.Task.run("compile")

alias Samen.Gen.App, as: Gen

# --- unique, COLLISION-CHECKED identities (fresh each run, collision-proof by construction)
# Delegated to `Samen.Gen.ProbeAbbrev.app_identity/5`: it searches the prefix + abbrev space
# (seeded fresh each run for the unique-scratch property) for an identity whose ENTIRE derived
# reserved set — billing + aggregate + the authored resource + the web Primitives/Operator
# families — is clear of the committed registry (`Samen.AbbrevRegistry.load/0`, the flattened
# global collision oracle) AND internally distinct, PLUS a second `resource_abbrev` (the
# `gen.resource` abbrev) clear of the registry, that family AND the app abbrev — advancing
# deterministically to the next candidate on ANY collision. This can never clash no matter how
# the committed registry grows; the old fixed-`j*` derivation + hand-remapped collisions
# (`jwh`/`jfl`) could, and twice DID, flake ci.sh. See Samen.Gen.ProbeAbbrev.
identity =
  Samen.Gen.ProbeAbbrev.app_identity(
    "Genpost",
    [web: true, api: true, target: "."],
    Samen.AbbrevRegistry.load(),
    System.unique_integer([:positive]),
    extra_resource?: true
  )

module = identity.module
prefix = identity.prefix
app_abbrev = identity.abbrev
resource_abbrev = identity.resource_abbrev

http_port = 4880 + rem(System.unique_integer([:positive]), 90)

samen_core_root = Gen.default_target() |> Path.join("samen_core")
scratch_root = Path.expand(Path.join(samen_core_root, ".."))

# T107: real `mktemp -d` — atomic, collision-immune, unique per run (was a fixed
# `_gen_post_scratch` name; two concurrent/orphaned runs of this probe could clash).
{scratch_parent_out, 0} =
  System.cmd("mktemp", ["-d", Path.join(scratch_root, "_gen_post_scratch.XXXXXX")])

scratch_parent = String.trim(scratch_parent_out)

# --- REGISTRY SAFETY: snapshot the committed registry FIRST ----------------------------
registry_path = Samen.AbbrevRegistry.path()
registry_pristine = File.read!(registry_path)

# T107: real `mktemp` (was a nanosecond-timestamp name) — atomically-created, guaranteed
# non-colliding even against a pre-planted stray file with the same naming shape.
{registry_scratch_out, 0} =
  System.cmd("mktemp", [Path.join(System.tmp_dir!(), "gen_post_registry_pristine.XXXXXX")])

registry_scratch = String.trim(registry_scratch_out)

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
    IO.puts("FATAL: could not restore the committed abbrev registry byte-exact — MANUAL " <>
              "RECHECK of #{registry_path} REQUIRED.")
    System.halt(2)
  end
end

halt = fn code, msg ->
  IO.puts(msg)
  cleanup.()
  System.halt(code)
end

# T107: SIGTERM defense-in-depth for standalone invocation (outside ci.sh). `:sigint` has
# no trap clause inside the BEAM — see the T107 note above the REGISTRY SAFETY section.
# SAMEN_T107_DISABLE_INNER_TRAP=1 skips installing this trap — used ONLY by
# scripts/interrupt_probe_test.sh's negative control, to isolate proof of the OUTER
# ci.sh-level trap (scripts/gen_probe_guard.sh) without this inner layer masking it.
if System.get_env("SAMEN_T107_DISABLE_INNER_TRAP") != "1" do
  System.trap_signal(:sigterm, :t107_post_probe_sigterm, fn ->
    IO.puts("\nFATAL: SIGTERM received — restoring registry from snapshot before exit.")
    cleanup.()
    System.halt(143)
  end)
end

IO.puts("== WS-D D7a POST-APP GENERATOR probe (AC-G4-7 / AC-G26-1/3) ==")
IO.puts("app=#{module} prefix=#{prefix} app_abbrev=#{app_abbrev} resource_abbrev=#{resource_abbrev}")

# --- helpers to run mix in the scratch app --------------------------------------------
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
    api: true,
    port: http_port
  )

try do
  Gen.validate!(spec)
  Gen.reserve_abbrevs!(spec)
  Gen.write_app!(spec)
  Gen.compile_and_dump!(spec)

  app_dir = spec.app_dir
  IO.puts("D7a: generated the base --web --api --seeds --observability app (#{module}).")

  # --- 2. gen.scope --------------------------------------------------------------------
  {scope_out, scope_code} = mix.(app_dir, ["samen.gen.scope", "--scope", "Crm"])

  if scope_code != 0 do
    IO.puts(scope_out)
    halt.(1, "FAIL: `mix samen.gen.scope --scope Crm` did not succeed.")
  end

  scope_file = Path.join(app_dir, "lib/#{spec.otp_app}/crm.ex")

  unless File.exists?(scope_file) do
    halt.(1, "FAIL: gen.scope did not write #{scope_file}.")
  end

  config_src = File.read!(Path.join(app_dir, "config/config.exs"))

  unless String.contains?(config_src, "#{module}.Crm") do
    halt.(1, "FAIL: gen.scope did not register #{module}.Crm in :ash_domains.")
  end

  IO.puts("D7a: gen.scope emitted #{module}.Crm + registered it in both :ash_domains lists.")

  # --- 3. gen.resource -----------------------------------------------------------------
  {res_out, res_code} =
    mix.(app_dir, [
      "samen.gen.resource",
      "--scope",
      "Crm",
      "--resource",
      "Widget",
      "--abbrev",
      resource_abbrev,
      # WS-D D7a `--live`: ALSO scaffold index/show/form LiveViews on `Samen.UI`.
      "--live",
      # ADR-040 §5.8 (T37h) `--archivable`: the emitted resource gets the FULL E6
      # substrate + the migration's archived_at column + (via --live) the generated
      # index LiveView's restore/archived-filter affordance — zero hand-edits.
      "--archivable"
    ])

  if res_code != 0 do
    IO.puts(res_out)
    halt.(1, "FAIL: `mix samen.gen.resource` did not succeed.")
  end

  four_files = [
    "test/crm_widget_policy_matrix_test.exs",
    "test/crm_widget_rbac_red_path_test.exs",
    "test/crm_widget_vault_routing_test.exs",
    "test/crm_widget_catalog_parity_red_path_test.exs"
  ]

  for f <- four_files do
    unless File.exists?(Path.join(app_dir, f)) do
      halt.(1, "FAIL: gen.resource did not emit the mandated test file #{f}.")
    end
  end

  unless File.exists?(Path.join(app_dir, "priv/crm_widget_anti_tautology_probe.exs")) do
    halt.(1, "FAIL: gen.resource did not emit the per-resource anti-tautology probe.")
  end

  resource_file = Path.join(app_dir, "lib/#{spec.otp_app}/crm/widget.ex")

  unless File.exists?(resource_file) do
    halt.(1, "FAIL: gen.resource did not emit the resource module #{resource_file}.")
  end

  # The resource must be wired into the Crm domain's resources block.
  unless File.read!(scope_file) =~ "resource(#{module}.Crm.Widget)" do
    halt.(1, "FAIL: gen.resource did not wire #{module}.Crm.Widget into the Crm domain.")
  end

  IO.puts("D7a: gen.resource emitted #{module}.Crm.Widget + migration + four G26 files + probe.")

  # --- 3b. --live: the three CRUD LiveViews + the mount-smoke test + router wiring -------
  live_files = [
    "lib/#{spec.otp_app}_web/crm/widget_index_live.ex",
    "lib/#{spec.otp_app}_web/crm/widget_show_live.ex",
    "lib/#{spec.otp_app}_web/crm/widget_form_live.ex"
  ]

  live_smoke_file = "test/crm_widget_live_smoke_test.exs"

  for f <- live_files do
    unless File.exists?(Path.join(app_dir, f)) do
      halt.(1, "FAIL: gen.resource --live did not emit the LiveView #{f}.")
    end
  end

  unless File.exists?(Path.join(app_dir, live_smoke_file)) do
    halt.(1, "FAIL: gen.resource --live did not emit the mount-smoke test #{live_smoke_file}.")
  end

  # The four `live/3` routes must be wired into the generated app's router.
  router_src = File.read!(Path.join(app_dir, "lib/#{spec.otp_app}_web/router.ex"))

  unless router_src =~ "Crm.WidgetIndexLive" and router_src =~ "Crm.WidgetShowLive" and
           router_src =~ "Crm.WidgetFormLive" do
    halt.(1, "FAIL: gen.resource --live did not wire the CRUD live/3 routes into the router.")
  end

  IO.puts("D7a: gen.resource --live emitted index/show/form LiveViews + smoke test + router routes.")

  # --- 3c. --archivable (ADR-040 §5.8, T37h): zero-hand-edit E6 substrate on the ---------
  #         emitted resource + migration + (via --live) the index LiveView's restore/
  #         archived-filter affordance. ---------------------------------------------------
  resource_src_check = File.read!(resource_file)

  unless resource_src_check =~ "archivable: true" do
    halt.(1, "FAIL: gen.resource --archivable did not emit `archivable: true` on #{resource_file}.")
  end

  widget_migration_files = Path.wildcard(Path.join(app_dir, "priv/repo/migrations/*_add_widget.exs"))

  case widget_migration_files do
    [widget_migration_file] ->
      unless File.read!(widget_migration_file) =~ ~r/#{resource_abbrev}_archived_at/ do
        halt.(1, "FAIL: gen.resource --archivable did not emit the archived_at column in #{widget_migration_file}.")
      end

    other ->
      halt.(1, "FAIL: expected exactly one *_add_widget.exs migration, found #{inspect(other)}.")
  end

  index_live_file = Path.join(app_dir, "lib/#{spec.otp_app}_web/crm/widget_index_live.ex")
  index_live_src = File.read!(index_live_file)

  unless index_live_src =~ ~s(phx-click="toggle_archived") and index_live_src =~ ~s(phx-click="restore") do
    halt.(1,
      "FAIL: `--live --archivable` did not emit the restore + archived-filter toggle " <>
        "affordance into #{index_live_file} — §5.8's UI clause must be inherited, not " <>
        "hand-wired, by any --live --archivable resource."
    )
  end

  IO.puts("D7a/§5.8: gen.resource --archivable emitted `archivable: true` + the migration's " <>
            "archived_at column + (via --live) the index LiveView's restore/toggle affordance " <>
            "— inherited, zero hand-edits.")

  # --- 4. re-dump the drift baseline (includes the new table), then run FULL ci.sh -----
  # compile first so catalog.dump sees the new resource; then re-baseline schema.dict.json
  # (the human's "commit the baseline" step), then the app's own ci.sh migrates + gates.
  {c_out, c_code} = mix.(app_dir, ["compile", "--warnings-as-errors"])

  if c_code != 0 do
    IO.puts(c_out)
    halt.(1, "FAIL: the app did not compile after gen.scope + gen.resource (hand-edit needed?).")
  end

  {_dump_out, dump_code} =
    mix.(app_dir, ["samen.catalog.dump", "--output", "schema.dict.json"])

  if dump_code != 0 do
    halt.(1, "FAIL: could not re-dump schema.dict.json after adding the resource.")
  end

  run_gate = fn ->
    System.cmd("bash", ["ci.sh"], cd: app_dir, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)
  end

  {gate_out, gate_code} = run_gate.()
  IO.puts("\nfull ci.sh exit (with the gen'd second scope+resource): #{gate_code}  (MUST be 0)")

  if gate_code != 0 do
    IO.puts(gate_out)
    halt.(1, "FAIL: ci.sh did NOT pass with the gen'd Crm.Widget resource — not correct-by-construction.")
  end

  # The four G26 files + the --live mount-smoke test must have RUN (not been silently
  # skipped). ci.sh runs `mix test`; confirm the modules were loaded by re-running JUST
  # them and asserting 0 failures.
  {t_out, t_code} =
    mix.(app_dir, ["test" | four_files ++ [live_smoke_file]])

  if t_code != 0 do
    IO.puts(t_out)
    halt.(1, "FAIL: the emitted G26 red-path + --live mount-smoke test files did not pass on a focused run.")
  end

  IO.puts("D7a: full ci.sh GREEN + the four G26 files pass (policy matrix, RBAC admin-gate,")
  IO.puts("     vault routing, catalog-parity) + the --live index/show/form mount-smoke —")
  IO.puts("     correct-by-construction, ZERO hand-edits.")

  # --- 4b. §5.8 flagship cycle: archive → hidden → restore → visible again, on the REAL --
  #         generated + migrated Crm.Widget (ci.sh above already ran `mix ecto.migrate`).
  archive_cycle_script = """
  # `config/test.exs` sets `start_repo?: false` (mix test's own DataCase owns the
  # sandboxed pool) — a plain `mix run -e` under MIX_ENV=test therefore does NOT start
  # the Repo via full app supervision. Start it directly (real pool, not sandboxed —
  # this script IS the only writer, no ExUnit concurrency to guard against here).
  {:ok, _} = #{module}.Repo.start_link()

  # The archive step below writes an `aud_event` row (archival audit). The generated app's
  # migration creates only the FIXED launch-month partition; the daily PartitionManager Oban job
  # that rolls partitions forward is not running under this bare `mix run`, so the current month's
  # partition may be absent. Provision current + upcoming months up front (forward-safe/idempotent
  # — exactly what the daily job does), else the archive audit hits "no partition of aud_event".
  Samen.AuditEvent.PartitionManager.ensure_upcoming_partitions(#{module}.Repo, Date.utc_today(), 2)

  alias #{module}.Crm.Widget
  org_id = Ash.UUID.generate()

  {:ok, w} =
    Widget
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      name: "archtest",
      label: "L",
      status: :active,
      secret: "s3cr3t-flagship-cycle"
    })
    |> Ash.create(authorize?: false)

  unless Enum.any?(Ash.read!(Widget, authorize?: false), &(&1.id == w.id)) do
    raise "FAIL: freshly-created Widget not visible in the default read"
  end

  {:ok, archived} = Samen.Archival.archive(w, authorize?: false)

  if archived.archived_at == nil do
    raise "FAIL: Samen.Archival.archive/2 did not set archived_at"
  end

  if Enum.any?(Ash.read!(Widget, authorize?: false), &(&1.id == w.id)) do
    raise "FAIL: archived Widget is STILL visible in the default read (hidden expected)"
  end

  {:ok, restored} = Samen.Archival.restore(archived, authorize?: false)

  if restored.archived_at != nil do
    raise "FAIL: Samen.Archival.restore/2 did not clear archived_at"
  end

  unless Enum.any?(Ash.read!(Widget, authorize?: false), &(&1.id == w.id)) do
    raise "FAIL: restored Widget is not visible again in the default read"
  end

  IO.puts("ARCHIVE_CYCLE: OK — archive -> hidden -> restore -> visible again, full round trip")
  """

  {cycle_out, cycle_code} = mix.(app_dir, ["run", "-e", archive_cycle_script])

  unless cycle_code == 0 and String.contains?(cycle_out, "ARCHIVE_CYCLE: OK") do
    IO.puts(cycle_out)
    halt.(1, "FAIL: the §5.8 archive/hidden/restore/visible cycle did not confirm on the generated --archivable Crm.Widget.")
  end

  IO.puts("D7a/§5.8: FLAGSHIP CYCLE CONFIRMED on the generated app — archive -> hidden from")
  IO.puts("          default read -> restore -> visible again, real Postgres round trip.")

  # --- 5. the per-resource anti-tautology probe confirms non-vacuity -------------------
  {probe_out, probe_code} =
    mix.(app_dir, ["run", "priv/crm_widget_anti_tautology_probe.exs"])

  if probe_code != 0 or not String.contains?(probe_out, "anti-tautology probe: CONFIRMED") do
    IO.puts(probe_out)
    halt.(1, "FAIL: the emitted per-resource anti-tautology probe did not confirm non-vacuity.")
  end

  IO.puts("D7a: the emitted anti-tautology probe CONFIRMED catalog-parity is non-vacuous.")

  # --- 6. SABOTAGE a red-path MECHANISM → the emitted red MUST flip ---------------------
  # Remove the `RoleAtLeast` admin gate from the generated resource: a member can now
  # create → the RBAC `admin_gate_red_path` (member create Forbidden) MUST fail.
  resource_pristine = File.read!(resource_file)

  gate_anchor = "      forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})\n"

  unless String.contains?(resource_pristine, gate_anchor) do
    halt.(1, "FAIL: could not find the RoleAtLeast admin gate to sabotage in #{resource_file}.")
  end

  sabotaged_resource = String.replace(resource_pristine, gate_anchor, "")
  File.write!(resource_file, sabotaged_resource)

  {sab_out, sab_code} = mix.(app_dir, ["test", "test/crm_widget_rbac_red_path_test.exs"])
  IO.puts("\nsabotage — removed the RoleAtLeast admin gate:")
  IO.puts("  rbac red-path exit: #{sab_code}  (MUST be non-zero — a member can now create)")

  if sab_code == 0 do
    IO.puts(sab_out)
    halt.(1, "FAIL: the RBAC admin-gate red path STILL PASSED with the gate removed — TAUTOLOGY.")
  end

  # Revert byte-exact → the red path passes again.
  File.write!(resource_file, resource_pristine)

  if File.read!(resource_file) != resource_pristine do
    halt.(1, "FAIL: the sabotage revert was not byte-exact.")
  end

  {rev_out, rev_code} = mix.(app_dir, ["test", "test/crm_widget_rbac_red_path_test.exs"])
  IO.puts("  revert rbac red-path exit: #{rev_code}  (MUST be 0 — green again)")

  if rev_code != 0 do
    IO.puts(rev_out)
    halt.(1, "FAIL: the sabotage revert did not restore the RBAC red path to green.")
  end

  IO.puts("D7a: sabotage CONFIRMED — removing the admin gate flipped the RBAC red path, recovered.")

  elapsed = System.monotonic_time(:millisecond) - t0

  IO.puts("\nRESULT: POST-APP GENERATOR PROBE CONFIRMED (AC-G4-7 / AC-G26-1/3) —")
  IO.puts("`mix samen.gen.scope` + `mix samen.gen.resource` scaffolded a second scope+resource")
  IO.puts("(Crm.Widget --live) correct-by-construction: it compiled, catalogued, reserved its")
  IO.puts("abbrev, emitted index/show/form LiveViews on Samen.UI wired into the router, passed")
  IO.puts("the full ci.sh with the four G26 red-path files green + the --live mount-smoke +")
  IO.puts("the per-resource anti-tautology probe, and a red-path-mechanism sabotage flipped a")
  IO.puts("red path and reverted byte-exact. Total probe runtime: #{Float.round(elapsed / 1000, 1)}s. Zero residue.")

  cleanup.()
rescue
  e ->
    cleanup.()
    IO.puts("FAIL: post-app generator probe crashed before completion: #{Exception.message(e)}")
    IO.puts(Exception.format(:error, e, __STACKTRACE__))
    System.halt(1)
end
