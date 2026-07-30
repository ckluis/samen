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
