# WS-D D2+D3 probe — the GENERATED WEB APP BOOTS AND SERVES, INCL. THE JSON:API
# (AC-G4-1 + AC-G4-2/3, the D2/D3 slice of AC-X-1).
#
# ADR-022's claim is that `mix samen.gen.app` (web + api ON by default) emits a RUNNING
# product, not just a gate-green data layer. A green that only asserts "ci.sh exits 0"
# cannot prove that — the web plane could be dead weight that never boots. This probe binds
# the claim to real behaviour:
#
#   1. GENERATE a full (web + api) app into a project-local scratch dir (fresh
#      registry-safe abbrevs); compile it; run its FULL ci.sh — the whole verifier gate
#      must PASS, which now INCLUDES the `samen.verify.api_contract` step against the
#      dumped api_contract.v1.json AND the gen'd API red-path suite inside `mix test`
#      (bounded-by-default index read, over-max page[limit] returns exactly the cap —
#      the PageLimitClamp e2e — and the un-allowlisted vault field absent from every
#      payload, AC-G4-3).
#   2. BOOT it — start the supervision tree in :test-with-repo mode (start_repo? forced on,
#      sandbox pool swapped for a real pool, endpoint server: true on a scratch port) and
#      assert over real HTTP:
#        * `/healthz`                → 200 "ok"           (the liveness probe)
#        * `/`                       → 200                 (the emitted landing page)
#        * `/billing?org=…`          → 200                 (a framework-mounted LiveView)
#        * `/notifications?org=…`    → 200                 (the WS-A inbox over Primitives)
#        * `/operator/accounts`      → 200                 (the ADR-010 operator plane)
#        * `/assets/samen_ui.css`    → 200                 (the UI kit via samen_web's priv)
#        * `/api/v1/records`         → 200 JSON:API        (WS-D D3 — the API BOOTS; the
#          key-less request is FAIL-CLOSED: no actor → OrgScope nil-org → zero rows)
#   3. RED PATH (AC-G4-10) — a `--headless` emission writes the ORIGINAL data-only file
#      set: no `*_web/` tree, no api tree, no primitives/operator mounts, no
#      phoenix/samen_web/ash_json_api dep.
#
# The paired priv/gen_app_gate_probe.exs stays the HEADLESS sabotage probe (the gate flips
# under a pii_-on-aggregate leak). Zero scratch residue; the registry is restored on exit.
#
# Run:  cd samen_core && mix run priv/gen_app_web_probe.exs
# Exit: 0 only if the gate passed, every route answered 200, and the headless red path held.

Mix.Task.run("compile")

alias Samen.Gen.App, as: Gen

# --- unique, collision-proof app identity (fresh abbrevs each run) ---------------------
# First prefix letter "h": the h* abbrev space is unowned in the committed registry, and
# the derived operator/primitives families (ho*/hp*/hq*/hn*) stay inside it.
suffix = System.unique_integer([:positive]) |> Integer.to_string() |> String.slice(-2, 2)
letters = for <<c <- suffix>>, do: rem(c - ?0, 26) + ?a
[l1, l2] = letters
# `f` is the ONE letter in the digit-derived a..j range whose billing-plan abbrev
# (`h` <> `f` <> `l` = "hfl") collides with the derived primitives file family
# (`h` <> "fl") — the generator correctly FAILS CLOSED on it (validate_against!/2
# internal-collision check, proven in gen_app_test). Remap it to `k` (outside every
# derived family: billing `h?[csl…]`, agg `h?a`, primitives `hn?`, operator `ho?/hp?/hq?`).
l1 = if l1 == ?f, do: ?k, else: l1
prefix = <<?h, l1>>
# Abbrev "hz<l2>": the `z` second letter keeps it clear of EVERY derived family — billing
# `h<l1>?` (l1 ∈ a-j), aggregate `h<l1>a`, primitives `hn?`, operator `ho?/hp?/hq?`.
resource_abbrev = <<?h, ?z, l2>>
module = "Genweb" <> String.upcase(<<l1, l2>>)

http_port = 4900 + rem(System.unique_integer([:positive]), 90)

samen_core_root = Gen.default_target() |> Path.join("samen_core")
scratch_parent = Path.join([samen_core_root, "..", "_gen_web_probe_scratch"]) |> Path.expand()

File.rm_rf!(scratch_parent)
File.mkdir_p!(scratch_parent)

registry_path = Samen.AbbrevRegistry.path()
registry_backup = File.read!(registry_path)

cleanup = fn ->
  File.write!(registry_path, registry_backup)
  File.rm_rf!(scratch_parent)
end

halt = fn code, msg ->
  IO.puts(msg)
  cleanup.()
  System.halt(code)
end

IO.puts("== WS-D D2+D3 probe: generated --web --api app gate + boot ==")
IO.puts("app module=#{module} prefix=#{prefix} abbrev=#{resource_abbrev} port=#{http_port}")

spec =
  Gen.build_spec(
    module: module,
    prefix: prefix,
    abbrev: resource_abbrev,
    target: scratch_parent,
    web: true,
    port: http_port
  )

try do
  Gen.validate!(spec)
rescue
  e -> halt.(1, "FAIL: generated spec did not validate: #{Exception.message(e)}")
end

try do
  Gen.reserve_abbrevs!(spec)
  Gen.write_app!(spec)
  Gen.compile_and_dump!(spec)

  app_dir = spec.app_dir
  otp_app = spec.otp_app

  # --- 1. GATE: the generated WEB app passes its own full ci.sh ------------------------
  {gate_out, gate_code} =
    System.cmd("bash", ["ci.sh"], cd: app_dir, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

  IO.puts("\nweb-app gate exit: #{gate_code}  (MUST be 0 — correct-by-construction incl. web)")

  if gate_code != 0 do
    IO.puts(gate_out)
    halt.(1, "FAIL: the generated --web app did NOT pass its gate.")
  end

  # --- 2. BOOT: start the tree in :test-with-repo mode, assert routes over HTTP --------
  org = "00000000-0000-4000-8000-0000000000d2"

  boot_script = """
  # D2 boot driver (scratch — written by gen_app_web_probe, NOT an emitted product file).
  # Runs under `mix run --no-start` in MIX_ENV=test: forces the repo + web plane ON,
  # swaps the sandbox pool for a real pool, serves the endpoint, and asserts over HTTP.

  kms = Path.join(System.tmp_dir!(), "#{otp_app}_boot_kms_\#{System.system_time(:nanosecond)}")
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
      IO.puts("BOOT PROBE FAIL: GET \#{path} → \#{code}")
      IO.puts(String.slice(body, 0, 2000))
      System.halt(1)
    end

    if expect && !String.contains?(body, expect) do
      IO.puts("BOOT PROBE FAIL: GET \#{path} → 200 but body lacks \#{inspect(expect)}")
      IO.puts(String.slice(body, 0, 2000))
      System.halt(1)
    end

    IO.puts("BOOT PROBE: GET \#{path} → 200 OK")
  end

  check.("/healthz", "ok")
  check.("/", "#{module}")
  check.("/billing?org=#{org}", nil)
  check.("/notifications?org=#{org}", nil)
  check.("/operator/accounts", nil)
  check.("/assets/samen_ui.css", nil)

  # WS-D D3 — the public JSON:API BOOTS AND SERVES over real HTTP.
  #
  # Seed one governed row + mint a real tenant api_key (the api_case idiom), then:
  #   1. KEY-LESS request → FAIL-CLOSED per the SHIPPED demo contract
  #      (demo/test/api_auth_red_path_test.exs): an empty 200 (KeyAuthPlug sets no
  #      actor → OrgScope's nil-org branch → zero rows) OR a 401/403 JSON:API error —
  #      both are "no data". Anything else (404 forward miss, 500 crash) fails.
  #      The seeded row must NOT leak (anti-tautology: it exists, the gate hides it).
  #   2. MINTED TENANT KEY → 200 WITH the seeded row (positive control — the pipeline
  #      KeyAuthPlug → Samen.Web.Api.PageLimitClamp → AshJsonApi router serves real
  #      governed data, so the key-less emptiness above is the auth gate, not an
  #      empty dataset).
  #   3. DENY-BY-DEFAULT over real HTTP: the un-allowlisted vault plaintext (`secret`)
  #      and the org boundary value never appear in the authorized payload.
  api_org = Ecto.UUID.generate()
  api_secret = "SECRET-BOOT-\#{System.unique_integer([:positive])}"

  {:ok, _record} =
    #{module}.Vertical.Record
    |> Ash.Changeset.for_create(:create, %{
      org_id: api_org,
      name: "BootProbeRecord",
      segment: "alpha",
      secret: api_secret
    })
    |> Ash.create(authorize?: false)

  {:ok, api_user} =
    #{module}.Operator.User
    |> Ash.Changeset.for_create(:create, %{
      handle: "boot-keymaster",
      org_id: api_org,
      full_name: %{first: "Boot", last: "Probe"},
      emails: ["boot-keymaster@example.com"]
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

  # 1. Key-less → fail-closed (the demo api_auth_red_path contract), no leak.
  {keyless_code, keyless_body} = get.("/api/v1/records")

  keyless_jsonapi? =
    String.contains?(keyless_body, "\\"data\\"") or
      String.contains?(keyless_body, "\\"errors\\"")

  if keyless_code in [200, 401, 403] and keyless_jsonapi? and
       not String.contains?(keyless_body, "BootProbeRecord") do
    IO.puts("BOOT PROBE: GET /api/v1/records (key-less) → \#{keyless_code} (fail-closed, no leak)")
  else
    IO.puts("BOOT PROBE FAIL: GET /api/v1/records (key-less) → \#{keyless_code}")
    IO.puts(String.slice(keyless_body, 0, 2000))
    System.halt(1)
  end

  # 2. Minted tenant key → 200 with the seeded row (the API SERVES, positive control).
  {api_code, api_body} = auth_get.("/api/v1/records")

  if api_code == 200 and String.contains?(api_body, "\\"data\\"") and
       String.contains?(api_body, "BootProbeRecord") do
    IO.puts("BOOT PROBE: GET /api/v1/records (tenant key) → 200 WITH the seeded row")
  else
    IO.puts("BOOT PROBE FAIL: GET /api/v1/records (tenant key) → \#{api_code}")
    IO.puts(String.slice(api_body, 0, 2000))
    System.halt(1)
  end

  # 3. Deny-by-default over real HTTP: un-allowlisted vault plaintext + org_id absent.
  if String.contains?(api_body, api_secret) or String.contains?(api_body, api_org) do
    IO.puts("BOOT PROBE FAIL: un-allowlisted field value leaked into the /api/v1 payload")
    IO.puts(String.slice(api_body, 0, 2000))
    System.halt(1)
  end

  IO.puts("BOOT PROBE: /api/v1/records payload omits the un-allowlisted secret/org_id")

  IO.puts("BOOT PROBE: ALL ROUTES 200")
  """

  boot_path = Path.join(app_dir, "_web_boot_probe.exs")
  File.write!(boot_path, boot_script)

  {boot_out, boot_code} =
    System.cmd("mix", ["run", "--no-start", "_web_boot_probe.exs"],
      cd: app_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )

  IO.puts("\nboot probe exit: #{boot_code}  (MUST be 0 — /healthz + framework routes 200)")
  IO.puts(boot_out |> String.split("\n") |> Enum.filter(&(&1 =~ "BOOT PROBE")) |> Enum.join("\n"))

  if boot_code != 0 or not String.contains?(boot_out, "BOOT PROBE: ALL ROUTES 200") do
    IO.puts(boot_out)
    halt.(1, "FAIL: the generated --web app did not boot + serve every mounted route.")
  end

  # --- 3. RED PATH: --headless emits the ORIGINAL data-only set (AC-G4-10) -------------
  headless_spec =
    Gen.build_spec(
      module: module <> "Headless",
      prefix: <<?h, l2>>,
      abbrev: <<?h, l2, l1>>,
      target: scratch_parent,
      web: false
    )

  # Emit-only (no reserve, no compile): the assertion is about the FILE SET.
  Gen.write_app!(headless_spec)
  headless_dir = headless_spec.app_dir

  emitted =
    Path.wildcard(Path.join(headless_dir, "**/*"), match_dot: true)
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, headless_dir))
    |> Enum.sort()

  web_leaks =
    Enum.filter(emitted, fn p ->
      String.contains?(p, "_web/") or String.contains?(p, "primitives.ex") or
        String.contains?(p, "operator.ex") or String.contains?(p, "mount_primitives") or
        String.contains?(p, "mount_operator")
    end)

  headless_mix = File.read!(Path.join(headless_dir, "mix.exs"))

  cond do
    length(emitted) != 28 ->
      halt.(1, "FAIL: headless emission wrote #{length(emitted)} files (expected the " <>
                 "original 28): #{inspect(emitted)}")

    web_leaks != [] ->
      halt.(1, "FAIL: headless emission leaked web files: #{inspect(web_leaks)}")

    String.contains?(headless_mix, "phoenix") or String.contains?(headless_mix, "samen_web") or
        String.contains?(headless_mix, "ash_json_api") ->
      halt.(1, "FAIL: headless mix.exs carries web/api deps.")

    true ->
      IO.puts("\nheadless red path: 28 data-only files, zero web/api emissions, no web deps — OK")
  end

  IO.puts("\nRESULT: PROBE CONFIRMED — the generated --web --api app passed its FULL gate")
  IO.puts("(incl. api_contract + the gen'd bounded/clamp/allowlist API red paths), booted,")
  IO.puts("and served /healthz + the billing/notifications/operator framework routes + the")
  IO.puts("samen_ui.css kit + the key-less fail-closed /api/v1/records JSON:API over real")
  IO.puts("HTTP; --headless reproduced the data-only emission.")

  cleanup.()
rescue
  e ->
    cleanup.()
    IO.puts("FAIL: probe crashed before completion: #{Exception.message(e)}")
    System.halt(1)
end
