# WS-D D10 — the DEPLOY proof (AC-G16-1 / AC-G16-2 / AC-G16-3, ADR-024 fail-honest).
#
# Claim: `mix samen.gen.app --deploy` emits FAIL-HONEST deploy artifacts — structurally
# correct + compile/parse, a BOOT-HONEST `config/runtime.exs` that RAISES on a missing
# secret rather than coming up half-secure, and an operator-TODO runbook — WITHOUT breaking
# the gate and WITHOUT claiming a live deploy. There is NO live Fly/Neon/KMS call anywhere.
#
# The run, end to end, in ONE automated pass:
#
#   1. GENERATE a fresh `--web --api --deploy` app into a project-local scratch dir with
#      FRESH registry-safe abbrevs; compile + dump baselines (Gen.compile_and_dump!/1) —
#      ZERO hand-edits. The compile alone proves the deploy artifacts (release.ex etc.)
#      compile cleanly.
#   2. AC-G16-1 (gate parity): run the generated app's FULL ci.sh — the whole verifier gate
#      + generated tests must STILL be green with the deploy layer present (deploy artifacts
#      don't break the gate). Then assert the six deploy artifacts exist and fly.toml is
#      structurally-valid TOML (the ADR-024 proof bound — parses, no live `fly` call; the
#      Dockerfile is NOT `docker build`-run: no live deploy execution, per §6).
#   3. AC-G16-2 (fail-closed, the RED PATH): evaluate the emitted `config/runtime.exs` with
#      `Config.Reader.read!(env: :prod)`:
#        * ALL required secrets set  → it does NOT raise (green path).
#        * a required secret UNSET   → it RAISES, and the message NAMES the missing secret
#          (boot-honest: the app refuses to come up half-secure) — proven for EACH of the
#          five required secrets.
#        * config_env() == :dev      → the prod block is skipped (no raise) — the fail-closed
#          posture is prod-only, so dev/test are unaffected.
#   4. SABOTAGE the raise (non-vacuity): rewrite runtime.exs so the KMS secret is read via a
#      bare `System.get_env(... ) || ""` FALLBACK instead of `fetch_secret!` — now a missing
#      SAMEN_KMS_KEY_ID must NO LONGER raise (the app would boot half-secure). The red-path
#      assertion MUST flip (detect the missing raise). Revert byte-exact → it raises again.
#      A fail-closed check whose sabotage cannot flip is a tautology.
#   5. AC-G16-3 (honest runbook): the emitted docs/runbooks/deploy.md has an explicit
#      "Operator TODO" block naming ALL FOUR human prerequisites (Fly account, Neon project,
#      KMS keys, OTLP exporter) and carries no aspirational "just run `fly deploy`".
#
# Zero scratch residue: the scratch app is removed and the committed abbrev registry is
# restored BYTE-EXACT from a scratch/tmp copy on every exit path (success, failure, crash);
# the restore is ASSERTED byte-equal.
#
# REGISTRY SAFETY (the standing carry): this probe NEVER treats the committed
# samen_core/priv/abbrev_registry.json as its own working copy. Pristine bytes are
# snapshotted to a scratch/tmp file FIRST; the reserve writes the app's abbrevs into the
# physical registry (unavoidable — the generated code reads `:code.priv_dir(:samen_core)` at
# ITS compile time), and the physical file is restored from the scratch copy on exit.
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
# Run:  cd samen_core && mix run priv/gen_app_deploy_probe.exs
# Exit: 0 only if the --deploy app generated with zero hand-edits, passed its full ci.sh
#       with the deploy layer present, its fly.toml parsed, its runtime.exs raised (naming
#       the secret) on EACH missing required secret + stayed silent when all were set, the
#       raise-sabotage flipped + reverted byte-exact, and the runbook named the four TODOs.

t0 = System.monotonic_time(:millisecond)

Mix.Task.run("compile")

alias Samen.Gen.App, as: Gen

# --- unique, COLLISION-CHECKED identity (fresh each run, collision-proof by construction) --
# Delegated to `Samen.Gen.ProbeAbbrev.app_identity/4`: it searches the prefix + abbrev space
# (seeded fresh each run for the unique-scratch property) for an identity whose ENTIRE derived
# reserved set — billing + aggregate + the authored resource + the web Primitives/Operator
# families — is clear of the committed registry (`Samen.AbbrevRegistry.load/0`, the flattened
# global collision oracle) AND internally distinct, advancing deterministically to the next
# candidate on ANY collision. This can never clash no matter how the committed registry grows;
# the old fixed-`j*` derivation + hand-remapped collisions could, and did, flake ci.sh.
# See Samen.Gen.ProbeAbbrev.
identity =
  Samen.Gen.ProbeAbbrev.app_identity(
    "Gendeploy",
    [web: true, api: true, target: "."],
    Samen.AbbrevRegistry.load(),
    System.unique_integer([:positive])
  )

module = identity.module
prefix = identity.prefix
resource_abbrev = identity.abbrev

http_port = 4790 + rem(System.unique_integer([:positive]), 90)

samen_core_root = Gen.default_target() |> Path.join("samen_core")
scratch_root = Path.expand(Path.join(samen_core_root, ".."))

# T107: real `mktemp -d` — atomic, collision-immune, unique per run (was a fixed
# `_gen_deploy_scratch` name; two concurrent/orphaned runs of this probe could clash).
{scratch_parent_out, 0} =
  System.cmd("mktemp", ["-d", Path.join(scratch_root, "_gen_deploy_scratch.XXXXXX")])

scratch_parent = String.trim(scratch_parent_out)

# --- REGISTRY SAFETY: snapshot the committed registry FIRST ----------------------------
registry_path = Samen.AbbrevRegistry.path()
registry_pristine = File.read!(registry_path)

# T107: real `mktemp` (was a nanosecond-timestamp name) — atomically-created, guaranteed
# non-colliding even against a pre-planted stray file with the same naming shape.
{registry_scratch_out, 0} =
  System.cmd("mktemp", [Path.join(System.tmp_dir!(), "gen_deploy_registry_pristine.XXXXXX")])

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
  System.trap_signal(:sigterm, :t107_deploy_probe_sigterm, fn ->
    IO.puts("\nFATAL: SIGTERM received — restoring registry from snapshot before exit.")
    cleanup.()
    System.halt(143)
  end)
end

# A minimal structural TOML validator (the ADR-024 proof bound — "fly.toml parses" without
# a live `fly` call / TOML dep): every non-blank, non-comment line is a `[section]` /
# `[[array]]` header (balanced brackets) OR a `key = value` pair.
toml_valid? = fn toml ->
  toml
  |> String.split("\n")
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  |> Enum.all?(fn line ->
    header? =
      String.starts_with?(line, "[") and String.ends_with?(line, "]") and
        (line |> String.graphemes() |> Enum.count(&(&1 == "["))) ==
          (line |> String.graphemes() |> Enum.count(&(&1 == "]")))

    kv? = Regex.match?(~r/\A\S+\s*=\s*.+\z/, line)
    header? or kv?
  end)
end

# Evaluate a runtime.exs file in a chosen config_env with a chosen secret env-map. Returns
# `:ok` if it evaluated without raising, or `{:raised, message}` if it raised. Restores the
# ambient env afterward. This is the load-bearing fail-closed check — NO app boot, NO live
# infra, just the config evaluation the release runs at boot.
required_secrets = ~w(DATABASE_URL SECRET_KEY_BASE PHX_HOST SAMEN_KMS_KEY_ID SAMEN_KMS_REGION)

eval_runtime = fn path, config_env, env_map ->
  saved = Map.new(required_secrets, fn k -> {k, System.get_env(k)} end)

  try do
    for k <- required_secrets, do: System.delete_env(k)
    for {k, v} <- env_map, do: System.put_env(k, v)

    try do
      _ = Config.Reader.read!(path, env: config_env)
      :ok
    rescue
      e -> {:raised, Exception.message(e)}
    end
  after
    for {k, v} <- saved do
      if v, do: System.put_env(k, v), else: System.delete_env(k)
    end
  end
end

all_secrets = %{
  "DATABASE_URL" => "postgres://u:p@h/db?sslmode=require",
  "SECRET_KEY_BASE" => String.duplicate("z", 64),
  "PHX_HOST" => "example.fly.dev",
  "SAMEN_KMS_KEY_ID" => "arn:aws:kms:us-east-1:0:key/abc",
  "SAMEN_KMS_REGION" => "us-east-1"
}

IO.puts("== WS-D D10 DEPLOY probe (AC-G16-1/2/3, ADR-024 fail-honest) ==")
IO.puts("app=#{module} prefix=#{prefix} abbrev=#{resource_abbrev} port=#{http_port}")

spec =
  Gen.build_spec(
    module: module,
    prefix: prefix,
    abbrev: resource_abbrev,
    target: scratch_parent,
    web: true,
    api: true,
    deploy: true,
    port: http_port
  )

try do
  Gen.validate!(spec)
  Gen.reserve_abbrevs!(spec)
  Gen.write_app!(spec)
  # deps.get + compile --warnings-as-errors (proves release.ex etc. compile) + dump baselines.
  Gen.compile_and_dump!(spec)

  app_dir = spec.app_dir
  otp_app = spec.otp_app

  IO.puts("D10: generated + compiled the --web --api --deploy app (#{module}), ZERO hand-edits.")

  # --- AC-G16-1: the deploy layer does NOT break the gate ------------------------------
  {gate_out, gate_code} =
    System.cmd("bash", ["ci.sh"], cd: app_dir, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

  IO.puts("\nDEPLOY gate exit: #{gate_code}  (MUST be 0 — deploy artifacts don't break ci.sh)")

  if gate_code != 0 do
    IO.puts(gate_out)
    halt.(1, "FAIL (AC-G16-1): the --deploy app did NOT pass its full ci.sh.")
  end

  IO.puts("DEPLOY: full ci.sh green with the deploy layer present (AC-G16-1).")

  # --- AC-G16-1 (structural): the six artifacts exist; fly.toml parses -----------------
  deploy_artifacts = [
    "fly.toml",
    "Dockerfile",
    "rel/env.sh.eex",
    "config/runtime.exs",
    "lib/#{otp_app}/release.ex",
    "docs/runbooks/deploy.md"
  ]

  for rel <- deploy_artifacts do
    unless File.exists?(Path.join(app_dir, rel)) do
      halt.(1, "FAIL (AC-G16-1): the --deploy app is missing the artifact #{rel}.")
    end
  end

  fly_toml = File.read!(Path.join(app_dir, "fly.toml"))

  unless toml_valid?.(fly_toml) do
    IO.puts(fly_toml)
    halt.(1, "FAIL (AC-G16-1): fly.toml is not structurally-valid TOML.")
  end

  unless String.contains?(fly_toml, "/readyz") and
           String.contains?(fly_toml, "release_command") and
           String.contains?(fly_toml, "internal_port = #{http_port}") do
    halt.(1, "FAIL (AC-G16-1): fly.toml lacks the /readyz check / release_command / endpoint port.")
  end

  IO.puts("DEPLOY: all 6 deploy artifacts present; fly.toml parses (health check + release_command + port).")

  # --- AC-G16-2: config/runtime.exs is FAIL-CLOSED (the red path) ----------------------
  runtime_path = Path.join(app_dir, "config/runtime.exs")
  runtime_pristine = File.read!(runtime_path)

  # (green) ALL secrets set → no raise.
  case eval_runtime.(runtime_path, :prod, all_secrets) do
    :ok ->
      IO.puts("DEPLOY: runtime.exs with ALL secrets set → boots (no raise). [green path]")

    {:raised, msg} ->
      halt.(1, "FAIL (AC-G16-2): runtime.exs raised even with ALL secrets set:\n#{msg}")
  end

  # (green) :dev env → the prod block is skipped, so a missing secret does NOT raise.
  case eval_runtime.(runtime_path, :dev, %{}) do
    :ok ->
      IO.puts("DEPLOY: runtime.exs in :dev (missing secrets) → no raise (prod-only fail-closed).")

    {:raised, msg} ->
      halt.(1, "FAIL (AC-G16-2): runtime.exs raised in :dev where the prod block should be skipped:\n#{msg}")
  end

  # (RED) each required secret UNSET in :prod → MUST raise, NAMING the missing secret.
  for missing <- required_secrets do
    env_map = Map.delete(all_secrets, missing)

    case eval_runtime.(runtime_path, :prod, env_map) do
      {:raised, msg} ->
        unless String.contains?(msg, missing) do
          halt.(
            1,
            "FAIL (AC-G16-2): runtime.exs raised on a missing #{missing} but the message " <>
              "did NOT name it (boot-honest requires an actionable named error):\n#{msg}"
          )
        end

        IO.puts("DEPLOY: runtime.exs with #{missing} UNSET → RAISED, naming #{missing}. [fail-closed]")

      :ok ->
        halt.(
          1,
          "FAIL (AC-G16-2): runtime.exs did NOT raise with #{missing} unset — the app would " <>
            "boot HALF-SECURE (fail-closed guarantee violated)."
        )
    end
  end

  # --- SABOTAGE the raise (non-vacuity): make SAMEN_KMS_KEY_ID optional ----------------
  # Replace the fail-closed fetch_secret! read of SAMEN_KMS_KEY_ID with a bare permissive
  # get_env fallback (empty string on absence). A missing key now yields "" instead of a
  # raise — the app would boot half-secure. The red-path check MUST detect the missing raise.
  # We locate the assignment `kms_key_id =\n ... fetch_secret!.(\n "SAMEN_KMS_KEY_ID", ... )`
  # (multi-line, /s dotall) and swap the whole reader for the permissive one.
  kms_call_regex =
    ~r/kms_key_id =\n\s*fetch_secret!\.\(\n\s*"SAMEN_KMS_KEY_ID",.*?\n\s*\)/s

  unless Regex.match?(kms_call_regex, runtime_pristine) do
    halt.(1, "FAIL: could not find the SAMEN_KMS_KEY_ID fail-closed read to sabotage in runtime.exs.")
  end

  permissive_read = "kms_key_id = System.get_env(\"SAMEN_KMS_KEY_ID\") || \"\""

  sabotaged_runtime =
    Regex.replace(kms_call_regex, runtime_pristine, permissive_read)

  if sabotaged_runtime == runtime_pristine do
    halt.(1, "FAIL: the runtime.exs sabotage did not change the file.")
  end

  File.write!(runtime_path, sabotaged_runtime)

  # Under sabotage, a missing SAMEN_KMS_KEY_ID must NO LONGER raise (proving the pristine
  # raise was load-bearing, not incidental).
  sab_env = Map.delete(all_secrets, "SAMEN_KMS_KEY_ID")

  case eval_runtime.(runtime_path, :prod, sab_env) do
    :ok ->
      IO.puts("DEPLOY: sabotage CONFIRMED — with the KMS read made permissive, a missing")
      IO.puts("        SAMEN_KMS_KEY_ID NO LONGER raises (the fail-closed raise was load-bearing).")

    {:raised, msg} ->
      File.write!(runtime_path, runtime_pristine)
      halt.(
        1,
        "FAIL: the fail-closed check is a TAUTOLOGY — runtime.exs STILL raised on a missing " <>
          "SAMEN_KMS_KEY_ID after the raise was sabotaged away:\n#{msg}"
      )
  end

  # Revert byte-exact → it fails closed again.
  File.write!(runtime_path, runtime_pristine)

  if File.read!(runtime_path) != runtime_pristine do
    halt.(1, "FAIL: the runtime.exs sabotage revert was not byte-exact.")
  end

  case eval_runtime.(runtime_path, :prod, sab_env) do
    {:raised, msg} ->
      unless String.contains?(msg, "SAMEN_KMS_KEY_ID") do
        halt.(1, "FAIL: post-revert raise did not name SAMEN_KMS_KEY_ID.")
      end

      IO.puts("DEPLOY: revert byte-exact — runtime.exs fails closed again on a missing SAMEN_KMS_KEY_ID.")

    :ok ->
      halt.(1, "FAIL: the runtime.exs sabotage revert did not restore the fail-closed raise.")
  end

  # --- AC-G16-3: the runbook names the four operator TODOs, honestly -------------------
  runbook = File.read!(Path.join(app_dir, "docs/runbooks/deploy.md"))

  unless String.contains?(runbook, "## Operator TODO") do
    halt.(1, "FAIL (AC-G16-3): docs/runbooks/deploy.md has no explicit Operator TODO block.")
  end

  todo = runbook |> String.split("## Operator TODO") |> List.last()

  todo_items = [
    {~r/Fly account/i, "Fly account"},
    {~r/Neon project/i, "Neon project"},
    {~r/KMS key/i, "KMS keys"},
    {~r/OTLP exporter/i, "OTLP exporter"}
  ]

  for {re, name} <- todo_items do
    unless Regex.match?(re, todo) do
      halt.(1, "FAIL (AC-G16-3): the Operator TODO block does not name the human prerequisite: #{name}.")
    end
  end

  if Regex.match?(~r/just run `fly deploy`/i, runbook) do
    halt.(1, "FAIL (AC-G16-3): the runbook is aspirational — it claims a turnkey `fly deploy`.")
  end

  IO.puts("DEPLOY: runbook Operator TODO names all four human prerequisites (Fly / Neon / KMS / OTLP); no turnkey claim.")

  # --- O5 / X6 (ADR-045 §4.2): the --deploy KMS posture FAILS HONEST AT BOOT, not per-op ---
  # The generated runtime.exs selects Samen.Kms.AwsKmsDynamo — a raise-only SKELETON. Prove the
  # generated prod app does NOT boot green and then 500 on every vault op: (1) runtime.exs selects
  # the skeleton with aws_kms_dynamo_enabled:FALSE (the O5/X6 defect shipped it as `true`),
  # (2) application.ex WIRES the framework boot guard, and (3) that guard REFUSES to boot in prod
  # when the skeleton adapter is selected — with a working adapter as the anti-tautology control.
  runtime_prod_cfg =
    (fn ->
       saved = Map.new(required_secrets, fn k -> {k, System.get_env(k)} end)

       try do
         for k <- required_secrets, do: System.delete_env(k)
         for {k, v} <- all_secrets, do: System.put_env(k, v)
         Config.Reader.read!(runtime_path, env: :prod)
       after
         for {k, v} <- saved do
           if v, do: System.put_env(k, v), else: System.delete_env(k)
         end
       end
     end).()

  core_cfg = Keyword.get(runtime_prod_cfg, :samen_core, [])
  selected_adapter = Keyword.get(core_cfg, :kms_adapter)
  enabled_flag = Keyword.get(core_cfg, :aws_kms_dynamo_enabled)

  unless selected_adapter == Samen.Kms.AwsKmsDynamo do
    halt.(1, "FAIL (O5): runtime.exs did not select Samen.Kms.AwsKmsDynamo (got #{inspect(selected_adapter)}).")
  end

  if enabled_flag != false do
    halt.(
      1,
      "FAIL (O5): runtime.exs set aws_kms_dynamo_enabled to #{inspect(enabled_flag)} — it MUST be " <>
        "false. A raise-only skeleton enabled in prod is the O5/X6 defect (boots green, 500s per op)."
    )
  end

  app_ex_src = File.read!(Path.join(app_dir, "lib/#{otp_app}/application.ex"))

  unless String.contains?(app_ex_src, "Samen.Kms.assert_prod_adapter_ready!") do
    halt.(1, "FAIL (O5): application.ex does not wire the KMS prod boot guard (Samen.Kms.assert_prod_adapter_ready!).")
  end

  IO.puts("DEPLOY: O5 — runtime.exs selects AwsKmsDynamo with aws_kms_dynamo_enabled:false; application.ex wires the boot guard.")

  # Behavioral proof: apply the runtime.exs-selected adapter to :samen_core and assert the boot
  # guard REFUSES in prod (naming the adapter + the ADR-001 §8.2 obligations), then a positive
  # control that it ADMITS a working adapter (FileBacked). Restores the ambient adapter after.
  saved_adapter = Application.get_env(:samen_core, :kms_adapter)

  try do
    Application.put_env(:samen_core, :kms_adapter, selected_adapter)

    boot =
      try do
        Samen.Kms.assert_prod_adapter_ready!(fn -> :prod end)
        :booted_green
      rescue
        e -> {:refused, Exception.message(e)}
      end

    case boot do
      {:refused, msg} ->
        unless String.contains?(msg, "AwsKmsDynamo") and String.contains?(msg, "ADR-001 §8.2") do
          halt.(1, "FAIL (O5): the boot guard refused but did NOT name the adapter + the ADR-001 §8.2 obligations:\n#{msg}")
        end

        IO.puts("DEPLOY: O5 — the prod boot guard REFUSES the raise-only KMS skeleton (names it + the ADR-001 §8.2 obligations). [fail-honest AT BOOT]")

      :booted_green ->
        halt.(
          1,
          "FAIL (O5): the prod boot guard did NOT refuse a raise-only KMS skeleton — the generated " <>
            "app would boot GREEN and then 500 on every vault op (the O5/X6 defect)."
        )
    end

    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Samen.Kms.assert_prod_adapter_ready!(fn -> :prod end)
    IO.puts("DEPLOY: O5 positive control — the boot guard ADMITS a working adapter (Samen.Kms.FileBacked).")
  after
    if saved_adapter,
      do: Application.put_env(:samen_core, :kms_adapter, saved_adapter),
      else: Application.delete_env(:samen_core, :kms_adapter)
  end

  # --- O4 (ADR-045 §4.2): the generated aud_event migration derives its REVOKE role -------------
  # It must NOT ship `REVOKE UPDATE, DELETE ON aud_event FROM clank` — a developer's laptop
  # Postgres role — into an adopter's prod migration (the O4 defect). The literal must be absent.
  aud_event_migration = File.read!(Path.join(app_dir, "priv/repo/migrations/20260705020000_aud_event.exs"))

  if String.contains?(aud_event_migration, "clank") do
    halt.(1, "FAIL (O4): the generated aud_event migration contains the hardcoded developer role 'clank'.")
  end

  unless String.contains?(aud_event_migration, "aud_event_app_role") do
    halt.(1, "FAIL (O4): the generated aud_event migration does not resolve the role via :aud_event_app_role.")
  end

  IO.puts("DEPLOY: O4 — the generated aud_event migration derives its REVOKE role (no hardcoded 'clank'); the migration RAN in the gate above.")

  # --- §2.1: the generated app has a config/prod.exs so a prod config-load does not abort -------
  prod_exs_path = Path.join(app_dir, "config/prod.exs")

  unless File.exists?(prod_exs_path) do
    halt.(1, "FAIL (§2.1): the generated app has no config/prod.exs — a prod config-load would abort on the missing import.")
  end

  case eval_runtime.(prod_exs_path, :prod, all_secrets) do
    :ok ->
      IO.puts("DEPLOY: §2.1 — the generated config/prod.exs exists and loads under Config.Reader in :prod.")

    {:raised, msg} ->
      halt.(1, "FAIL (§2.1): the generated config/prod.exs did not load in :prod:\n#{msg}")
  end

  elapsed = System.monotonic_time(:millisecond) - t0

  IO.puts("\nRESULT: DEPLOY PROBE CONFIRMED (AC-G16-1/2/3) — `mix samen.gen.app --deploy` emitted")
  IO.puts("fail-honest deploy artifacts that, with ZERO hand-edits: passed the full ci.sh (deploy")
  IO.puts("layer doesn't break the gate), parsed as valid fly.toml, fail-CLOSED on EACH missing")
  IO.puts("secret (naming it) while staying silent when all are set + in :dev; the fail-closed raise")
  IO.puts("was proven load-bearing (sabotage flipped it, revert byte-exact); and the runbook named")
  IO.puts("the four operator TODOs with no live-deploy claim. No live Fly/Neon/KMS call anywhere.")
  IO.puts("Total probe runtime: #{Float.round(elapsed / 1000, 1)}s. Zero scratch residue.")

  cleanup.()
rescue
  e ->
    cleanup.()
    IO.puts("FAIL: deploy probe crashed before completion: #{Exception.message(e)}")
    IO.puts(Exception.format(:error, e, __STACKTRACE__))
    System.halt(1)
end
