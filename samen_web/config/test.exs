import Config

config :samen_web, Samen.WebTest.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_web_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# Quiet Ecto's per-query debug logging in the test suite (the render tests issue many reads).
config :samen_web, Samen.WebTest.Repo, log: false

# The library does not boot an application supervisor; the test setup starts the repo.
config :samen_web, start_repo?: false

config :samen_core, Oban, testing: :manual, plugins: false

# The test-support host domains exist only in :test (test/support). Register them under
# :samen_web (for `mix ash.*` niceties) but NOT under :samen_core :ash_domains — the render
# tests + PiiResolution reference resources by module directly, so samen_core does not need
# to discover them, and listing not-yet-compiled test/support domains during samen_core's
# own compile would raise a spurious "not a Spark DSL module" verifier warning.
config :samen_web,
  ash_domains: [
    Samen.WebTest.Crm,
    Samen.WebTest.Billing,
    Samen.WebTest.Support
  ]
