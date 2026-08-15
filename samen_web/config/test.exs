import Config

config :samen_web, Samen.WebTest.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_web_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  # pool_size 20 + queue slack (mirrors samen_core config/test.exs, WS-B B9 gate F1 /
  # WS-F4 QA): the render suite fans out many concurrent DB-backed reads under the
  # shared sandbox; the default 4s queue timeout could hit checkout pressure under an
  # unlucky seed. Headroom kills the flake — not a correctness change.
  pool_size: 20,
  queue_target: 200,
  queue_interval: 2_000

config :logger, level: :warning

# Quiet Ecto's per-query debug logging in the test suite (the render tests issue many reads).
config :samen_web, Samen.WebTest.Repo, log: false

# The library does not boot an application supervisor; the test setup starts the repo.
config :samen_web, start_repo?: false

config :samen_core, Oban, testing: :manual, plugins: false

# T82 fix round (fail-honest MED): Samen.Fleet.Registry.cockpit_identity/1
# refuses (fail-honest) unless a host EXPLICITLY configures
# :fleet_local_credential — this test suite opts into the reference
# (non-durable in-process) implementation explicitly, mirroring
# samen_core/config/test.exs.
config :samen_core, :fleet_local_credential, Samen.Fleet.LocalCredential.Agent

# A5 (AC-G5-3): the sample-data offer is FAIL-CLOSED by default (env defaults :prod,
# enabled defaults false). The test host declares its env; the RP-G5-3 red path
# overrides this at runtime to prove the prod-without-flag refusal.
config :samen_web, Samen.Web.SampleData, env: :test

# The test-support host domains exist only in :test (test/support). Register them under
# :samen_web (for `mix ash.*` niceties) but NOT under :samen_core :ash_domains — the render
# tests + PiiResolution reference resources by module directly, so samen_core does not need
# to discover them, and listing not-yet-compiled test/support domains during samen_core's
# own compile would raise a spurious "not a Spark DSL module" verifier warning.
config :samen_web,
  ash_domains: [
    Samen.WebTest.Crm,
    Samen.WebTest.Billing,
    Samen.WebTest.Support,
    Samen.WebTest.Work,
    Samen.WebTest.Calendar,
    Samen.WebTest.Marketing,
    Samen.WebTest.Operator,
    Samen.WebTest.Primitives,
    Samen.WebTest.RichTypes,
    Samen.WebTest.Automation
  ]

# T84b / P8 (phase6-punchlist) — `mix samen.verify.fleet_wire`'s closed-catalog
# MEMBERSHIP check (Samen.Fleet.Report.Catalogs, Samen.Fleet.Report.Schema.validate/2)
# needs a REAL declared catalog to smoke-check against — a fixture, not production
# vocabulary. Declaring it here has NO effect on any other fleet test: the ingest
# HTTP path (Samen.Web.Fleet.{Ingress,CockpitIngress}) calls Schema.validate/1
# (the 1-arg default, catalogs: %{}), and Samen.Fleet.Report.build/1's own default
# emits empty checks/oban/mrr_by_tier/activity_counts lists, so no existing fleet
# test payload carries a catalog-shaped value this config could reject.
config :samen_web, :fleet_wire_catalogs,
  closed_check_catalog: ~w(db_reachable redis_reachable queue_healthy),
  closed_plan_tier_catalog: ~w(free pro enterprise),
  closed_app_queue_catalog: ~w(mailers webhooks reports),
  closed_audit_taxonomy_catalog: ~w(login logout org_update billing_update)

# B-SEC (luminary pre-merge, S5) — the ONLY endpoint in this library, and it exists ONLY for
# the LiveView-driving tenant-authz red-path suite (`test/samen/web/tenant_authz_live_test.exs`).
# Before it, NO test in the repo drove a tenant LiveView through a real router: every
# tenant-authn proof asserted `Samen.Web.CurrentOrg.resolve/3` as a unit function, which is why
# the `handle_params`-on-dead-render bypass passed every gate. `server: false` — the suite drives
# it through Phoenix.ConnTest / Phoenix.LiveViewTest, never a listening socket.
config :samen_web, Samen.WebTest.SecurityEndpoint,
  secret_key_base: String.duplicate("samen-web-security-probe-", 4),
  live_view: [signing_salt: "sec-probe-lv"],
  render_errors: [formats: [html: Samen.WebTest.SecurityErrorHTML], layout: false],
  server: false

# NOTE: the fictional host app the probe arms/disarms (`:samen_web_security_test_host`) is
# deliberately NOT configured here — it is not a real dependency, and an unset
# `:auth_required?` already reads as DISARMED (`Application.get_env(app, :auth_required?, false)`).
# The suite flips it at runtime via `Samen.WebTest.SecurityHost.arm!/0`.

# A5 fold F1 (ADR-047; the A4 verifier's R2): the approver-membership seam pointed at the
# REAL materialized Identity mount the test support carries, so `Samen.AI.Agent.Approver`'s
# Ash-RESOURCE path is exercised against a genuine `use Samen.Scopes.Identity` Membership
# table (samen_core exercises the {module, function} path against a fixture). Test-env only:
# `Samen.WebTest.Operator` is test-support, and an unwired env must stay fail-closed.
config :samen_core, Samen.AI.Agent, approver_membership: Samen.WebTest.Operator.Membership
