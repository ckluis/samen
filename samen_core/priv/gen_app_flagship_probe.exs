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
#      all default-ON) PLUS `--modules files,search,csv,settings` (WS-E: the four ≈0-LOC
#      framework end-user surfaces + the Samen.UI menu landing), into a project-local scratch
#      dir, using FRESH registry-safe abbrevs.
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
#        * /files · /search · /settings · /csv/import/record → 200  (WS-E --modules surfaces)
#        * /                     → the Samen.UI HomeLive MENU listing every mounted surface
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
# Run:  cd samen_core && mix run priv/gen_app_flagship_probe.exs
# Exit: 0 only if the FULL running product generated with zero hand-edits, its ci.sh passed,
#       it seeded + booted + served every route, and BOTH sabotages flipped the gate and
#       reverted byte-exact with zero residue.

t0 = System.monotonic_time(:millisecond)

Mix.Task.run("compile")

alias Samen.Gen.App, as: Gen

# --- unique, COLLISION-CHECKED app identity (fresh each run, collision-proof by construction)
# Delegated to `Samen.Gen.ProbeAbbrev.app_identity/4`: it searches the prefix + abbrev space
# (seeded fresh each run for the unique-scratch property) for an identity whose ENTIRE derived
# reserved set — billing + aggregate + the authored resource + the web Primitives/Operator
# families — is clear of the committed registry (`Samen.AbbrevRegistry.load/0`, the flattened
# global collision oracle) AND internally distinct, advancing deterministically to the next
# candidate on ANY collision. This can never clash no matter how the committed registry grows;
# the old fixed-`j*` derivation + hand-remapped collisions (`jfl`) could, and DID, flake ci.sh.
# See Samen.Gen.ProbeAbbrev.
identity =
  Samen.Gen.ProbeAbbrev.app_identity(
    "Genflag",
    [web: true, api: true, target: "."],
    Samen.AbbrevRegistry.load(),
    System.unique_integer([:positive])
  )

module = identity.module
prefix = identity.prefix
resource_abbrev = identity.abbrev

http_port = 4990 + rem(System.unique_integer([:positive]), 90)

samen_core_root = Gen.default_target() |> Path.join("samen_core")
scratch_root = Path.expand(Path.join(samen_core_root, ".."))

# T107: real `mktemp -d` — atomic, collision-immune, unique per run (was a fixed
# `_gen_flagship_scratch` name; two concurrent/orphaned runs of this probe could clash).
{scratch_parent_out, 0} =
  System.cmd("mktemp", ["-d", Path.join(scratch_root, "_gen_flagship_scratch.XXXXXX")])

scratch_parent = String.trim(scratch_parent_out)

# --- REGISTRY SAFETY: snapshot the committed registry to a scratch/tmp copy FIRST -----
registry_path = Samen.AbbrevRegistry.path()
registry_pristine = File.read!(registry_path)

# T107: real `mktemp` (was a nanosecond-timestamp name) — atomically-created, guaranteed
# non-colliding even against a pre-planted stray file with the same naming shape.
{registry_scratch_out, 0} =
  System.cmd("mktemp", [Path.join(System.tmp_dir!(), "flagship_registry_pristine.XXXXXX")])

registry_scratch = String.trim(registry_scratch_out)

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

# T107: SIGTERM defense-in-depth for standalone invocation (outside ci.sh). `:sigint` has
# no trap clause inside the BEAM — see the T107 note above the REGISTRY SAFETY section.
# SAMEN_T107_DISABLE_INNER_TRAP=1 skips installing this trap — used ONLY by
# scripts/interrupt_probe_test.sh's negative control, to isolate proof of the OUTER
# ci.sh-level trap (scripts/gen_probe_guard.sh) without this inner layer masking it.
if System.get_env("SAMEN_T107_DISABLE_INNER_TRAP") != "1" do
  System.trap_signal(:sigterm, :t107_flagship_probe_sigterm, fn ->
    IO.puts("\nFATAL: SIGTERM received — restoring registry from snapshot before exit.")
    cleanup.()
    System.halt(143)
  end)
end

IO.puts("== WS-D D6 FLAGSHIP probe (AC-X-1): --web --api --seeds --observability ==")
IO.puts("app module=#{module} prefix=#{prefix} abbrev=#{resource_abbrev} port=#{http_port}")

# WS-E `--modules`: mount the four ≈0-LOC framework end-user surfaces (files/search/csv over
# Primitives/Vertical, settings over the Operator Identity namespace) AND surface them as a
# menu (the Samen.UI HomeLive landing). This binds the `--modules` selection to real behaviour:
# the mounted routes must serve, and the menu must render — with the full ci.sh still green and
# a byte-exact registry afterward. (`chat` is deliberately omitted: it is documented-with-
# prerequisite, not auto-mounted — proven by the unit suite, not this boot probe.)
selected_modules = "files,search,csv,settings"

spec =
  Gen.build_spec(
    module: module,
    prefix: prefix,
    abbrev: resource_abbrev,
    target: scratch_parent,
    web: true,
    api: true,
    modules: selected_modules,
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

  # The generated app's `aud_event` migration creates only the FIXED launch-month partition; in a
  # real deployment the daily `Samen.AuditEvent.PartitionManager` Oban job rolls partitions
  # forward, but on a FRESH boot before that job's first run (or when the wall clock is already
  # past the launch month) the current month's partition is absent — so the boot+archive probe's
  # audit write would hit "no partition of relation aud_event". Provision the current + upcoming
  # months up front, exactly what the daily job does (forward-safe; the ensure is idempotent).
  Samen.AuditEvent.PartitionManager.ensure_upcoming_partitions(#{module}.Repo, Date.utc_today(), 2)

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

  # B10/T26 — the billing SETTINGS page, EMITTED by gen.app with zero hand-edits (the
  # route flows automatically through the already-templated `samen_module_routes(:billing,
  # ...)` line, via samen_web's own `__routes__(:billing, path)` route table — no
  # router_ex.eex change needed). This generated app never wires `:billing_provider`
  # (no default gen.app config slot for it, same posture as the onboarding wizard's
  # `:plan_labels` hook), so the page MUST render the honest "bring your billing" empty
  # state (ADR-038 §3.5 B10) — the exact copy, asserted here, not just a 200.
  check.("/billing/settings?org=#{org}", "No billing provider is configured for this workspace")

  check.("/notifications?org=#{org}", nil)
  check.("/operator/accounts", nil)
  check.("/assets/samen_ui.css", nil)

  # --- WS-E `--modules`: the four mounted surface routes serve (dead-render 200) -----------
  check.("/files?org=#{org}", nil)
  check.("/search?org=#{org}", nil)
  check.("/settings?org=#{org}", nil)
  check.("/csv/import/record?org=#{org}", nil)

  # --- WS-E `--modules`: the MENU renders — the Samen.UI HomeLive landing at `/` lists the
  #     mounted surfaces as real navigation (the "undocumented as a menu" fix). -------------
  {menu_code, menu_body} = get.("/")
  menu_labels = ["Files", "Search", "Settings", "CSV import", "Product"]

  if menu_code == 200 and Enum.all?(menu_labels, &String.contains?(menu_body, &1)) do
    IO.puts("FLAGSHIP: GET / → 200 Samen.UI menu (HomeLive) lists every mounted surface")
  else
    IO.puts("FLAGSHIP FAIL: GET / did not render the --modules menu (code " <> Integer.to_string(menu_code) <> ")")
    IO.puts(String.slice(menu_body, 0, 2000))
    System.halt(1)
  end

  # --- The public JSON:API: key-less fail-closed, tenant key serves, deny-by-default ---
  api_org = Ecto.UUID.generate()
  api_secret = "SECRET-FLAGSHIP-\#{System.unique_integer([:positive])}"

  {:ok, flagship_record} =
    #{module}.Vertical.Record
    |> Ash.Changeset.for_create(:create, %{
      org_id: api_org,
      name: "FlagshipRecord",
      segment: "alpha",
      secret: api_secret
    })
    |> Ash.create(authorize?: false)

  # --- T37h (ADR-040 §5.8): the default-archivable Vertical.Record — archive → hidden
  #     from the default read → restore → visible again, on THIS generated app's real DB.
  {:ok, flagship_archived} = Samen.Archival.archive(flagship_record, authorize?: false)

  if flagship_archived.archived_at == nil do
    IO.puts("FLAGSHIP FAIL: Samen.Archival.archive/2 did not set archived_at on Vertical.Record")
    System.halt(1)
  end

  if Enum.any?(Ash.read!(#{module}.Vertical.Record, authorize?: false), &(&1.id == flagship_record.id)) do
    IO.puts("FLAGSHIP FAIL: archived Vertical.Record is STILL visible in the default read")
    System.halt(1)
  end

  {:ok, flagship_restored} = Samen.Archival.restore(flagship_archived, authorize?: false)

  if flagship_restored.archived_at != nil do
    IO.puts("FLAGSHIP FAIL: Samen.Archival.restore/2 did not clear archived_at")
    System.halt(1)
  end

  unless Enum.any?(Ash.read!(#{module}.Vertical.Record, authorize?: false), &(&1.id == flagship_record.id)) do
    IO.puts("FLAGSHIP FAIL: restored Vertical.Record is not visible again in the default read")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: §5.8 archive -> hidden -> restore -> visible again on the default-archivable Vertical.Record")

  # --- T37h (gen-approval-golden fold-in): reveal-approve routes THROUGH Samen.Approvals,
  #     NOT the pre-T35 inline fallback — `mix samen.gen.app` now wires
  #     `config :samen_core, Samen.Approvals` + emits `lib/#{otp_app}/approvals.ex` +
  #     its migration, closing the T35 verifier's non-fatal note. Proof: Grants.request/1's
  #     dual-write opens a REAL pii_reveal Approval row (an unwired host would silently
  #     no-op there — `open_engine_approval/1` rescues to `:ok`), and Grants.approve/2
  #     transitions that SAME row to :approved (the inline fallback never touches it —
  #     a host stuck on the fallback would leave it :pending forever).
  reveal_subject = "flagship-subject-\#{System.unique_integer([:positive])}"
  reveal_requestor = "flagship-requestor-\#{System.unique_integer([:positive])}"
  reveal_granter = "flagship-granter-\#{System.unique_integer([:positive])}"

  baseline_approvals = length(Ash.read!(#{module}.Approvals.Approval, authorize?: false))

  {:ok, reveal_req} =
    Samen.Reveal.Grants.request(%{
      subject_id: reveal_subject,
      requestor_id: reveal_requestor,
      reason: "flagship-probe-audit-review"
    })

  after_request_approvals = length(Ash.read!(#{module}.Approvals.Approval, authorize?: false))

  if after_request_approvals != baseline_approvals + 1 do
    IO.puts("FLAGSHIP FAIL: Grants.request/1 did not open a pii_reveal Approval through " <>
              "Samen.Approvals (baseline \#{baseline_approvals}, after \#{after_request_approvals}) " <>
              "— reveal-approve is on the pre-T35 inline fallback, not the engine.")
    System.halt(1)
  end

  {:ok, _reveal_grant} = Samen.Reveal.Grants.approve(reveal_req, %{granted_by: reveal_granter})

  approval_row =
    #{module}.Approvals.Approval
    |> Ash.read!(authorize?: false)
    |> Enum.find(&(&1.requested_by == reveal_requestor))

  if approval_row == nil or approval_row.state != :approved do
    IO.puts("FLAGSHIP FAIL: the pii_reveal Approval row did not transition to :approved via " <>
              "Grants.approve/2 (found \#{inspect(approval_row && approval_row.state)}) — " <>
              "reveal-approve did NOT route through Samen.Approvals.")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: T37h reveal-approve routes THROUGH Samen.Approvals (Approval opened by " <>
            "Grants.request/1, approved -> :approved by Grants.approve/2) — not the pre-T35 " <>
            "inline fallback.")

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

  # =========================================================================
  # A9 — the FULL AUTH SPINE, emitted by `mix samen.gen.app` with ZERO hand-edits
  # (spec A9 + T10 addenda 1-4). The generated app is the FIRST host to serve the
  # entire framework auth path. This drives the DOMAIN flow (signup -> verify ->
  # invite) end to end over the generated `#{module}.Operator` Identity mount AND
  # asserts every auth surface is reachable over real HTTP.
  # =========================================================================

  # The invite step dispatches through the fail-honest `Samen.Delivery.AuthMailer`
  # chokepoint. samen_core is compiled as a path dep here, so its compiled-in
  # delivery env is not necessarily `:test` — set it EXPLICITLY (the house
  # convention every auth test follows) so the mailer CAPTURES via
  # `Samen.Delivery.LocalSink` (returning `{:ok, receipt}`) instead of the
  # unconfigured-adapter fail-honest `{:error, :adapter_unconfigured}`.
  Application.put_env(:samen_core, :delivery_env, :test)

  reg_mods = %{
    org: #{module}.Operator.Org,
    credential: #{module}.Operator.Credential,
    user: #{module}.Operator.User,
    membership: #{module}.Operator.Membership,
    auth_token: #{module}.Operator.AuthToken,
    repo: #{module}.Repo
  }

  reg_attrs = fn ->
    n = System.unique_integer([:positive])

    %{
      org_name: "Flagship Org \#{n}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "flagship-\#{n}@example.test",
      password: "correct horse battery staple"
    }
  end

  # --- SIGNUP (A1): creates Org + Credential + User + owner Membership atomically ---
  inviter_attrs = reg_attrs.()

  {:ok, inviter} = Samen.Identity.Register.register(inviter_attrs, reg_mods)

  unless inviter.status == :registered and inviter.membership.role == :owner and
           is_binary(inviter.org.id) and is_binary(inviter.user.id) do
    IO.puts("FLAGSHIP FAIL: signup did not create org/user/owner-membership")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: signup (A1) created org+user+owner-membership atomically")

  # --- Addendum 4: the auth notification actually LANDS (engine wired, not a no-op) ---
  require Ash.Query

  signup_notifications =
    #{module}.Primitives.Notification
    |> Ash.Query.filter(org_id == ^inviter.org.id)
    |> Ash.Query.filter(recipient_id == ^inviter.user.id)
    |> Ash.Query.filter(event_type == "auth.signup")
    |> Ash.Query.ensure_selected([:id, :event_type, :org_id, :recipient_id])
    |> Ash.read!(authorize?: false)

  if signup_notifications == [] do
    IO.puts("FLAGSHIP FAIL: no auth.signup notification landed — Notifications.Engine is not " <>
              "wired (config :samen_core, Samen.Notifications.Engine) and the A10 fan-out no-op'd")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: Addendum 4 — auth.signup notification LANDED (engine wired, fan-out dispatched)")

  # --- VERIFY (A2): the email-verify token round-trips (single-use) ---
  confirm_mods = %{
    credential: #{module}.Operator.Credential,
    auth_token: #{module}.Operator.AuthToken,
    user: #{module}.Operator.User,
    repo: #{module}.Repo
  }

  case Samen.Identity.Confirm.consume(inviter.raw_verify_token, confirm_mods) do
    {:ok, _} -> :ok
    other ->
      IO.puts("FLAGSHIP FAIL: email-verify token did not round-trip: \#{inspect(other)}")
      System.halt(1)
  end

  # Single-use: a SECOND consume of the SAME token must now fail (proves it was consumed).
  case Samen.Identity.Confirm.consume(inviter.raw_verify_token, confirm_mods) do
    {:error, _} -> :ok
    other ->
      IO.puts("FLAGSHIP FAIL: verify token was NOT single-use (second consume: \#{inspect(other)})")
      System.halt(1)
  end

  IO.puts("FLAGSHIP: verify (A2) token round-tripped + is single-use")

  # --- INVITE (A5): an invite lands a Membership in the INVITING org ---
  invitee_attrs = reg_attrs.()
  {:ok, invitee} = Samen.Identity.Register.register(invitee_attrs, reg_mods)

  invite_mods = %{
    invitation: #{module}.Operator.Invitation,
    credential: #{module}.Operator.Credential,
    user: #{module}.Operator.User,
    membership: #{module}.Operator.Membership,
    repo: #{module}.Repo
  }

  inviter_scope = %Samen.Scope{
    actor: %{
      id: inviter.user.id,
      org_id: inviter.org.id,
      role: :owner,
      verified?: true,
      kind: :tenant,
      plane: :tenant
    }
  }

  {:ok, _invitation, raw_invite_token} =
    Samen.Identity.Invite.create(invite_mods, inviter_scope, %{email: invitee_attrs.email, role: :member})

  memberships_before =
    #{module}.Operator.Membership
    |> Ash.Query.filter(org_id == ^inviter.org.id)
    |> Ash.count!(authorize?: false)

  case Samen.Identity.Invite.accept(invite_mods, raw_invite_token) do
    {:ok, _joined} -> :ok
    other ->
      IO.puts("FLAGSHIP FAIL: invite accept did not land a membership: \#{inspect(other)}")
      System.halt(1)
  end

  memberships_after =
    #{module}.Operator.Membership
    |> Ash.Query.filter(org_id == ^inviter.org.id)
    |> Ash.count!(authorize?: false)

  unless memberships_after == memberships_before + 1 do
    IO.puts("FLAGSHIP FAIL: invite accept did not add a membership to the inviting org " <>
              "(before \#{memberships_before}, after \#{memberships_after})")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: invite (A5) accept landed a membership in the inviting org")

  # --- A8 first-run wizard: OFFERED for the fresh org; plan hook is the HONEST empty state ---
  onboard_mount = Samen.Web.Mount.new(:settings, #{module}.Operator, #{module}.Repo, labels: %{})

  unless Samen.Web.Onboarding.needed?(onboard_mount, inviter_scope, inviter.org.id) do
    IO.puts("FLAGSHIP FAIL: the A8 onboarding wizard is not offered for a fresh org")
    System.halt(1)
  end

  # INV-4: with NO :plan_labels hook wired (the default generated app has no billing
  # plan source), plan selection is the fail-honest :not_configured empty state — never
  # a fabricated plan list.
  unless Samen.Web.Onboarding.plan_choices(onboard_mount, inviter.org.id) == :not_configured do
    IO.puts("FLAGSHIP FAIL: onboarding plan hook did not render the honest empty state " <>
              "(a plan list was fabricated with no :plan_labels wired)")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: A8 wizard offered + plan hook is the honest :not_configured empty state (INV-4)")

  # --- Addendum 3: the :authn prod gate closes the spoofable ?org= URL-param path ---
  # Built EXACTLY as the generated router's billing mount is (labels: @current_org_labels).
  authn_mount =
    Samen.Web.Mount.new(:billing, #{module}.Billing, #{module}.Repo,
      labels: %{authn: {:app_env, :#{otp_app}, :auth_required?}}
    )

  arbitrary_org = Ecto.UUID.generate()

  # Positive control (dev/test default: auth_required? false) — the query param resolves.
  Application.put_env(:#{otp_app}, :auth_required?, false)

  unless Samen.Web.CurrentOrg.resolve(authn_mount, %{"org" => arbitrary_org}, %{}) == arbitrary_org do
    IO.puts("FLAGSHIP FAIL: with auth off, the ?org= param did not resolve (control broken)")
    System.halt(1)
  end

  # The FIX (prod: auth_required? true) — an UNAUTHENTICATED request can NOT resolve an
  # arbitrary org via ?org=; the spoofable path is closed (nil, not the arbitrary org).
  Application.put_env(:#{otp_app}, :auth_required?, true)
  spoofed = Samen.Web.CurrentOrg.resolve(authn_mount, %{"org" => arbitrary_org}, %{})
  Application.put_env(:#{otp_app}, :auth_required?, false)

  if spoofed == arbitrary_org do
    IO.puts("FLAGSHIP FAIL: Addendum 3 — with auth_required? TRUE an unauthenticated ?org= " <>
              "STILL resolved an arbitrary org (\#{inspect(spoofed)}) — the prod gate is a TAUTOLOGY")
    System.halt(1)
  end

  IO.puts("FLAGSHIP: Addendum 3 — :authn prod gate closes the spoofable ?org= URL-param path")

  # --- Every auth surface is reachable over real HTTP (zero hand-edits) ---
  check.("/signup", "Create your account")
  check.("/login", nil)
  check.("/onboarding?org=#{org}", nil)
  check.("/onboarding?org=\#{inviter.org.id}&user=\#{inviter.user.id}", nil)
  # Settings/Security (mounted via --modules settings, spine_totp on) + the 2FA-enroll
  # route that had NO HTTP mount before Addendum 2 (2FA was unreachable in prod).
  check.("/settings/security?org=\#{inviter.org.id}&user=\#{inviter.user.id}", nil)
  check.("/settings/security/2fa?credential_id=\#{inviter.credential.id}", "auth-totp-enroll")

  IO.puts("FLAGSHIP: auth spine reachable over HTTP — /signup /login /onboarding " <>
            "/settings/security /settings/security/2fa (Addendum 2: 2FA-enroll route live)")

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
