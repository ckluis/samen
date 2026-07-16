# WS-D D6 — the FLAGSHIP generative proof (AC-X-1).
#
# The north-star claim of the whole workstream (design.md §"North star"): `mix samen.gen.app`
# emits a RUNNING product — web + API + seeds + observability — that is correct-by-construction
# from zero, the way pawchart is, WITHOUT a single hand-edit. A green that only asserts "ci.sh
# exits 0" cannot prove that: the running surfaces could be dead weight, the gate could be
# toothless, the seeds could bypass the vault, the observability could leak SQL text. This probe
# binds the claim to real behaviour, end to end, in ONE automated run:
#
#   1. GENERATE a fresh app with the FULL running product (web + api + seeds + observability,
#      all default-ON) into a project-local scratch dir, using FRESH registry-safe abbrevs.
#   2. deps.get + `mix compile --warnings-as-errors` (via Gen.compile_and_dump!/1, which also
#      dumps the schema.dict + api_contract.v1.json baselines) — ZERO hand-edits.
#   3. Run the generated app's FULL ci.sh — the entire verifier gate (18 steps incl.
#      api_contract), the generated test suite (incl. the gen'd red-paths: record_vault,
#      the bounded/clamp/allowlist API red paths, the seeds vault-routing red path), and the
#      per-resource anti-tautology probe. It must PASS (exit 0).
#   4. SEED it via the emitted `mix <app>.seed` task, and confirm the seeds ran (the task
#      prints the seeded org id; the seeded 🔒 secrets are proven vault-routed by the gen'd
#      seeds_vault_test that step 3 already ran, and re-verified here by a raw-row scan).
#   5. BOOT it — start the supervision tree in :test-with-repo mode (real pool, endpoint
#      server:true on a scratch port) and assert over real HTTP:
#        * /healthz              → 200 "ok"          (liveness)
#        * /                     → 200                (the emitted landing page)
#        * /billing?org=…        → 200                (a framework-mounted LiveView)
#        * /notifications?org=…  → 200                (the WS-A inbox)
#        * /operator/accounts    → 200                (the ADR-010 operator plane)
#        * /assets/samen_ui.css  → 200                (the UI kit via samen_web priv)
#        * /api/v1/records       → key-less FAIL-CLOSED (no leak); tenant key → 200 with data;
#          the un-allowlisted vault secret + org boundary NEVER appear (deny-by-default).
#   6. TWO SABOTAGES binding the new surfaces to real correctness (non-vacuity):
#        (a) delete a `show_fields` entry from the authored resource → the generated app's
#            `samen.verify.api_contract` step MUST flip to FAIL; revert → green again.
#        (b) drop `db_statement: :disabled` from the wired observability config → the
#            generated app's `no_plaintext_pii` tier MUST flip to FAIL; revert → green again.
#      Both reverts are byte-exact; both flips are proven (a probe whose sabotage cannot flip
#      is a tautology and halts non-zero).
#
# Zero scratch residue: the scratch app is removed and the committed abbrev registry is
# restored BYTE-EXACT from a scratch/tmp copy on every exit path (success, failure, crash) —
# and the restore is ASSERTED byte-equal (the probe fails loudly rather than leave residue).
#
# REGISTRY SAFETY (the D2/D3 gate carry): this probe NEVER treats the committed
# samen_core/priv/abbrev_registry.json as its own working copy. The pristine bytes are
# snapshotted to a scratch/tmp file FIRST; the reserve then writes the app's abbrevs into the
# physical registry (unavoidable — the generated app's `use Samen.Resource` reads
# `:code.priv_dir(:samen_core)` at ITS compile time), and the physical file is restored from
# the scratch copy on exit. The scratch copy is the source of truth for the restore.
#
# Run:  cd samen_core && mix run priv/gen_app_flagship_probe.exs
# Exit: 0 only if the FULL running product generated with zero hand-edits, its ci.sh passed,
#       it seeded + booted + served every route, and BOTH sabotages flipped the gate and
#       reverted byte-exact with zero residue.

t0 = System.monotonic_time(:millisecond)

Mix.Task.run("compile")

alias Samen.Gen.App, as: Gen

# --- unique, collision-proof app identity (fresh abbrevs each run) ---------------------
# First prefix letter "j": the j* abbrev space is unowned in the committed registry, and
# the derived operator/primitives families (jo*/jp*/jq*/jn*) stay inside it.
suffix =
  System.unique_integer([:positive])
  |> Integer.to_string()
  |> String.pad_leading(2, "0")
  |> String.slice(-2, 2)
letters = for <<c <- suffix>>, do: rem(c - ?0, 26) + ?a
[l1, l2] = letters
# `f` is the one digit-derived (a..j) letter whose billing abbrev "j"<>"f"<>"l" = "jfl"
# collides with the derived primitives family "j"<>"fl". Remap to `k` (outside every family).
l1 = if l1 == ?f, do: ?k, else: l1
prefix = <<?j, l1>>
# Abbrev "jz<l2>": the `z` second letter keeps it clear of billing (j<l1>?), aggregate
# (j<l1>a), primitives (jn?), operator (jo?/jp?/jq?).
resource_abbrev = <<?j, ?z, l2>>
module = "Genflag" <> String.upcase(<<l1, l2>>)

http_port = 4990 + rem(System.unique_integer([:positive]), 90)

samen_core_root = Gen.default_target() |> Path.join("samen_core")
scratch_parent = Path.join([samen_core_root, "..", "_gen_flagship_scratch"]) |> Path.expand()

File.rm_rf!(scratch_parent)
File.mkdir_p!(scratch_parent)

# --- REGISTRY SAFETY: snapshot the committed registry to a scratch/tmp copy FIRST -----
registry_path = Samen.AbbrevRegistry.path()
registry_pristine = File.read!(registry_path)

registry_scratch =
  Path.join(System.tmp_dir!(), "flagship_registry_pristine_#{System.system_time(:nanosecond)}.json")

File.write!(registry_scratch, registry_pristine)

restored_clean? = fn ->
  # Restore the physical registry FROM the scratch copy and assert byte-equality.
  File.write!(registry_path, File.read!(registry_scratch))
  File.read!(registry_path) == registry_pristine
end

cleanup = fn ->
  ok? = restored_clean?.()
  File.rm_rf!(scratch_parent)
  File.rm(registry_scratch)

  unless ok? do
    IO.puts("FATAL: could not restore the committed abbrev registry byte-exact from the " <>
              "scratch copy — MANUAL RECHECK of #{registry_path} REQUIRED.")
    System.halt(2)
  end
end

halt = fn code, msg ->
  IO.puts(msg)
  cleanup.()
  System.halt(code)
end

IO.puts("== WS-D D6 FLAGSHIP probe (AC-X-1): --web --api --seeds --observability ==")
IO.puts("app module=#{module} prefix=#{prefix} abbrev=#{resource_abbrev} port=#{http_port}")

spec =
  Gen.build_spec(
    module: module,
    prefix: prefix,
    abbrev: resource_abbrev,
    target: scratch_parent,
    web: true,
    api: true,
    port: http_port
  )

try do
  Gen.validate!(spec)
rescue
  e -> halt.(1, "FAIL: generated spec did not validate: #{Exception.message(e)}")
end

try do
  # Reserve into the PHYSICAL registry (unavoidable — see the REGISTRY SAFETY note). The
  # pristine bytes are safe in registry_scratch; cleanup restores byte-exact from it.
  Gen.reserve_abbrevs!(spec)
  Gen.write_app!(spec)
  # deps.get + compile --warnings-as-errors + dump schema.dict + dump api_contract.v1.json.
  Gen.compile_and_dump!(spec)

  app_dir = spec.app_dir
  otp_app = spec.otp_app

  run_gate = fn ->
    System.cmd("bash", ["ci.sh"], cd: app_dir, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)
  end

  # --- 1. FULL ci.sh: the whole verifier gate + generated test suite + red-paths -------
  {gate_out, gate_code} = run_gate.()
  IO.puts("\nflagship gate exit: #{gate_code}  (MUST be 0 — correct-by-construction, ZERO hand-edits)")

  if gate_code != 0 do
    IO.puts(gate_out)
    halt.(1, "FAIL: the generated --web --api --seeds --observability app did NOT pass its full ci.sh.")
  end

  # The gate suite must have RUN the gen'd seeds vault-routing red path (D4) — assert it
  # was present + green, not silently absent (a suite that skips it proves nothing).
  unless File.exists?(Path.join(app_dir, "test/seeds_vault_test.exs")) do
    halt.(1, "FAIL: the generated app is missing the seeds vault-routing red path (D4).")
  end

  IO.puts("FLAGSHIP: full ci.sh green — verifier gate (18 steps incl. api_contract) + gen'd")
  IO.puts("          test suite (record_vault, API bounded/clamp/allowlist, seeds vault) + probe.")

  # --- 2. SEED via the emitted `mix <app>.seed`, then BOOT + HTTP-probe ----------------
  # A single boot script: run the seed task's Seeds.run/0 inside the booted app (the mix
  # task wraps exactly this), assert the seeded rows are vault-routed at rest, then probe
  # every mounted route + the JSON:API bounds over real HTTP.
  org = "00000000-0000-4000-8000-0000000000d6"

  boot_script = """
  # D6 flagship boot+seed driver (scratch — written by the probe, NOT an emitted file).
  # Runs under `mix run --no-start` in MIX_ENV=test: forces repo + web ON, real pool,
  # serves the endpoint, SEEDS via the app's Seeds module (what `mix <app>.seed` wraps),
  # proves the seed is vault-routed, then asserts every route over HTTP.

  kms = Path.join(System.tmp_dir!(), "#{otp_app}_flagship_kms_\#{System.system_time(:nanosecond)}")
  File.rm_rf!(kms)
  Application.put_env(:samen_core, :kms_key_dir, kms)

  Application.put_env(:#{otp_app}, :start_repo?, true)

  repo_cfg =
    Application.get_env(:#{otp_app}, #{module}.Repo)
    |> Keyword.put(:pool, DBConnection.ConnectionPool)

  Application.put_env(:#{otp_app}, #{module}.Repo, repo_cfg)

  endpoint_cfg =
    Application.get_env(:#{otp_app}, #{module}Web.Endpoint)
    |> Keyword.merge(server: true, http: [ip: {127, 0, 0, 1}, port: #{http_port}])

  Application.put_env(:#{otp_app}, #{module}Web.Endpoint, endpoint_cfg)

  {:ok, _} = Application.ensure_all_started(:#{otp_app})

  # `mix run` prunes unused-OTP-app code paths; restore inets for the HTTP client.
  Mix.ensure_application!(:inets)
  {:ok, _} = Application.ensure_all_started(:inets)

  # --- SEED via the app's Seeds module (the exact call `mix #{otp_app}.seed` makes) ----
  seed_org = #{module}.Seeds.run()

  unless seed_org == #{module}.Seeds.org_id() do
    IO.puts("FLAGSHIP FAIL: seed did not return the expected org id")
    System.halt(1)
  end

  # Prove the seed is vault-routed AT REST (D4/AC-G4-4): the raw domain column holds a
  # vt_* token, and NONE of the seeded plaintext secrets appear at rest.
  seeded_plaintexts =
    #{module}.Seeds.records() |> Enum.map(fn {_n, _s, secret} -> secret end)

  org_dumped = Ecto.UUID.dump!(seed_org)

  %{rows: raw_rows} =
    Ecto.Adapters.SQL.query!(
      #{module}.Repo,
      "SELECT pii_#{spec.abbrev}_secret FROM #{spec.resource_table} WHERE #{spec.abbrev}_org_id = $1",
      [org_dumped]
    )

  raw_secrets = Enum.map(raw_rows, fn [r] -> r end)

  if raw_secrets == [] do
    IO.puts("FLAGSHIP FAIL: seed wrote no rows for the seed org")
    System.halt(1)
  end

  leaked =
    Enum.any?(raw_secrets, fn raw ->
      not (is_binary(raw) and String.starts_with?(raw, "vt_")) or raw in seeded_plaintexts
    end)

  if leaked do
    IO.puts("FLAGSHIP FAIL: a seeded 🔒 secret is at rest as plaintext (vault bypassed)")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: `mix #{otp_app}.seed` seeded \#{length(raw_secrets)} rows — all vault-routed (vt_*), no plaintext at rest")

  get = fn path ->
    url = ~c"http://127.0.0.1:#{http_port}\#{path}"

    case :httpc.request(:get, {url, []}, [], body_format: :binary) do
      {:ok, {{_, code, _}, _hdrs, body}} -> {code, body}
      other -> raise "HTTP GET \#{path} failed: \#{inspect(other)}"
    end
  end

  check = fn path, expect ->
    {code, body} = get.(path)

    unless code == 200 do
      IO.puts("FLAGSHIP FAIL: GET \#{path} → \#{code}")
      IO.puts(String.slice(body, 0, 2000))
      System.halt(1)
    end

    if expect && !String.contains?(body, expect) do
      IO.puts("FLAGSHIP FAIL: GET \#{path} → 200 but body lacks \#{inspect(expect)}")
      System.halt(1)
    end

    IO.puts("FLAGSHIP: GET \#{path} → 200 OK")
  end

  check.("/healthz", "ok")
  check.("/", "#{module}")
  check.("/billing?org=#{org}", nil)
  check.("/notifications?org=#{org}", nil)
  check.("/operator/accounts", nil)
  check.("/assets/samen_ui.css", nil)

  # --- The public JSON:API: key-less fail-closed, tenant key serves, deny-by-default ---
  api_org = Ecto.UUID.generate()
  api_secret = "SECRET-FLAGSHIP-\#{System.unique_integer([:positive])}"

  {:ok, _record} =
    #{module}.Vertical.Record
    |> Ash.Changeset.for_create(:create, %{
      org_id: api_org,
      name: "FlagshipRecord",
      segment: "alpha",
      secret: api_secret
    })
    |> Ash.create(authorize?: false)

  {:ok, api_user} =
    #{module}.Operator.User
    |> Ash.Changeset.for_create(:create, %{
      handle: "flagship-keymaster",
      org_id: api_org,
      full_name: %{first: "Flag", last: "Ship"},
      emails: ["flagship-keymaster@example.com"]
    })
    |> Ash.create(authorize?: false)

  {:ok, api_mbr} =
    #{module}.Operator.Membership
    |> Ash.Changeset.for_create(:create, %{role: :admin, org_id: api_org, user_id: api_user.id})
    |> Ash.create(authorize?: false)

  raw_api_key = "sk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  {:ok, _key} =
    #{module}.Operator.ApiKey
    |> Ash.Changeset.for_create(:create, %{
      plane: :tenant,
      scopes: %{"vertical" => ["read"]},
      minter_role: :admin,
      org_id: api_org,
      membership_id: api_mbr.id
    })
    |> Ash.Changeset.force_change_attribute(
      :token_digest,
      #{module}Web.Api.KeyAuthPlug.digest(raw_api_key)
    )
    |> Ash.create(authorize?: false)

  auth_get = fn path ->
    url = ~c"http://127.0.0.1:#{http_port}\#{path}"
    headers = [{~c"authorization", String.to_charlist("Bearer " <> raw_api_key)}]

    case :httpc.request(:get, {url, headers}, [], body_format: :binary) do
      {:ok, {{_, code, _}, _hdrs, body}} -> {code, body}
      other -> raise "HTTP GET \#{path} failed: \#{inspect(other)}"
    end
  end

  {keyless_code, keyless_body} = get.("/api/v1/records")

  keyless_jsonapi? =
    String.contains?(keyless_body, "\\"data\\"") or String.contains?(keyless_body, "\\"errors\\"")

  if keyless_code in [200, 401, 403] and keyless_jsonapi? and
       not String.contains?(keyless_body, "FlagshipRecord") do
    IO.puts("FLAGSHIP: GET /api/v1/records (key-less) → \#{keyless_code} (fail-closed, no leak)")
  else
    IO.puts("FLAGSHIP FAIL: GET /api/v1/records (key-less) → \#{keyless_code}")
    IO.puts(String.slice(keyless_body, 0, 2000))
    System.halt(1)
  end

  {api_code, api_body} = auth_get.("/api/v1/records")

  if api_code == 200 and String.contains?(api_body, "\\"data\\"") and
       String.contains?(api_body, "FlagshipRecord") do
    IO.puts("FLAGSHIP: GET /api/v1/records (tenant key) → 200 WITH the row (API bounds serve)")
  else
    IO.puts("FLAGSHIP FAIL: GET /api/v1/records (tenant key) → \#{api_code}")
    IO.puts(String.slice(api_body, 0, 2000))
    System.halt(1)
  end

  if String.contains?(api_body, api_secret) or String.contains?(api_body, api_org) do
    IO.puts("FLAGSHIP FAIL: an un-allowlisted field value leaked into the /api/v1 payload")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: /api/v1/records payload omits the un-allowlisted secret/org_id (deny-by-default)")
  IO.puts("FLAGSHIP: ALL ROUTES 200")
  """

  boot_path = Path.join(app_dir, "_flagship_boot_probe.exs")
  File.write!(boot_path, boot_script)

  {boot_out, boot_code} =
    System.cmd("mix", ["run", "--no-start", "_flagship_boot_probe.exs"],
      cd: app_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )

  IO.puts("\nboot+seed exit: #{boot_code}  (MUST be 0 — seeded + /healthz + framework routes 200)")
  IO.puts(boot_out |> String.split("\n") |> Enum.filter(&(&1 =~ "FLAGSHIP")) |> Enum.join("\n"))

  if boot_code != 0 or not String.contains?(boot_out, "FLAGSHIP: ALL ROUTES 200") do
    IO.puts(boot_out)
    halt.(1, "FAIL: the generated app did not seed + boot + serve every mounted route.")
  end

  File.rm(boot_path)

  # --- 3. SABOTAGE (a): delete a `show_fields` entry → api_contract MUST flip ----------
  vertical = Path.join(app_dir, "lib/#{otp_app}/vertical.ex")
  vertical_pristine = File.read!(vertical)

  show_anchor = "show_fields([:id, :name, :segment])"

  unless String.contains?(vertical_pristine, show_anchor) do
    halt.(1, "FAIL: could not find the `show_fields` allowlist to sabotage in #{vertical}.")
  end

  sabotaged_vertical =
    String.replace(vertical_pristine, show_anchor, "show_fields([:id, :name])")

  File.write!(vertical, sabotaged_vertical)

  # Wrong-flip guard (D4-6 gate OBS-1): step banners are echoed on EVERY run, so a bare
  # substring match is satisfied regardless of where the gate died. ci.sh is
  # `set -euo pipefail`, so the LAST echoed "--- step N/M:" line IS the failing step.
  last_step = fn out ->
    case Regex.scan(~r/--- step \d+\/\d+:[^\n]*/, out) |> List.last() do
      nil -> ""
      [line] -> line
    end
  end

  # Re-run ci.sh WITHOUT re-dumping the api_contract snapshot: the committed snapshot still
  # lists `segment`, the recompiled resource no longer serves it → structural break → fail.
  {sab_a_out, sab_a_code} = run_gate.()
  IO.puts("\nsabotage (a) — dropped :segment from show_fields:")
  IO.puts("  gate exit: #{sab_a_code}  (MUST be non-zero — api_contract structural break)")

  if sab_a_code == 0 do
    IO.puts(sab_a_out)
    halt.(1, "FAIL: gate STILL PASSED after de-allowlisting an API field — api_contract is a TAUTOLOGY.")
  end

  unless String.contains?(last_step.(sab_a_out), "api_contract") do
    IO.puts(sab_a_out)

    halt.(
      1,
      "FAIL: gate failed under sabotage (a) but NOT at the api_contract step " <>
        "(last step reached: #{inspect(last_step.(sab_a_out))} — wrong flip)."
    )
  end

  # Revert byte-exact; the committed snapshot already matches the pristine resource → green.
  File.write!(vertical, vertical_pristine)

  if File.read!(vertical) != vertical_pristine do
    halt.(1, "FAIL: sabotage (a) revert was not byte-exact.")
  end

  {rev_a_out, rev_a_code} = run_gate.()
  IO.puts("  revert gate exit: #{rev_a_code}  (MUST be 0 — green again)")

  if rev_a_code != 0 do
    IO.puts(rev_a_out)
    halt.(1, "FAIL: sabotage (a) revert did not restore the gate to green.")
  end

  IO.puts("FLAGSHIP: sabotage (a) CONFIRMED — api_contract flipped on a de-allowlisted field, recovered.")

  # --- 4. SABOTAGE (b): drop `db_statement: :disabled` → no_plaintext_pii MUST flip ----
  config = Path.join(app_dir, "config/config.exs")
  config_pristine = File.read!(config)

  db_anchor = "config :#{otp_app}, :opentelemetry_ecto, db_statement: :disabled"

  unless String.contains?(config_pristine, db_anchor) do
    halt.(1, "FAIL: could not find the observability db_statement config to sabotage in #{config}.")
  end

  # Comment the line out (drop the un-forgettable posture) — the OTel-Ecto dep is still
  # present, so the LogTelemetry tier now sees an unproven SQL-text surface → violation.
  sabotaged_config =
    String.replace(config_pristine, db_anchor, "# (sabotage) " <> db_anchor)

  File.write!(config, sabotaged_config)

  {sab_b_out, sab_b_code} = run_gate.()
  IO.puts("\nsabotage (b) — dropped db_statement: :disabled from observability config:")
  IO.puts("  gate exit: #{sab_b_code}  (MUST be non-zero — no_plaintext_pii LogTelemetry flip)")

  if sab_b_code == 0 do
    IO.puts(sab_b_out)
    halt.(1, "FAIL: gate STILL PASSED with SQL-text recording unproven — no_plaintext_pii is a TAUTOLOGY.")
  end

  unless String.contains?(last_step.(sab_b_out), "no_plaintext_pii") do
    IO.puts(sab_b_out)

    halt.(
      1,
      "FAIL: gate failed under sabotage (b) but NOT at the no_plaintext_pii step " <>
        "(last step reached: #{inspect(last_step.(sab_b_out))} — wrong flip)."
    )
  end

  File.write!(config, config_pristine)

  if File.read!(config) != config_pristine do
    halt.(1, "FAIL: sabotage (b) revert was not byte-exact.")
  end

  {rev_b_out, rev_b_code} = run_gate.()
  IO.puts("  revert gate exit: #{rev_b_code}  (MUST be 0 — green again)")

  if rev_b_code != 0 do
    IO.puts(rev_b_out)
    halt.(1, "FAIL: sabotage (b) revert did not restore the gate to green.")
  end

  IO.puts("FLAGSHIP: sabotage (b) CONFIRMED — no_plaintext_pii flipped on a dropped db_statement, recovered.")

  elapsed = System.monotonic_time(:millisecond) - t0

  IO.puts("\nRESULT: FLAGSHIP PROBE CONFIRMED (AC-X-1) — `mix samen.gen.app` emitted a RUNNING")
  IO.puts("product (web + api + seeds + observability) that, with ZERO hand-edits: passed its")
  IO.puts("full ci.sh (verifier gate + generated tests + all red-paths), seeded vault-aware via")
  IO.puts("`mix #{otp_app}.seed`, booted + served /healthz + the framework LiveViews + the")
  IO.puts("bounded deny-by-default JSON:API over real HTTP; and BOTH new sabotages (API")
  IO.puts("allowlist, observability db_statement) flipped the gate and reverted byte-exact.")
  IO.puts("Total probe runtime: #{Float.round(elapsed / 1000, 1)}s. Zero scratch residue.")

  cleanup.()
rescue
  e ->
    cleanup.()
    IO.puts("FAIL: flagship probe crashed before completion: #{Exception.message(e)}")
    IO.puts(Exception.format(:error, e, __STACKTRACE__))
    System.halt(1)
end
