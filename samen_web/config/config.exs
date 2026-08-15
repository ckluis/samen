import Config

# ADR-036 D1 / ADR-037 §5.2: AshMoney/ex_money wiring — the mounted test-support
# CRM Opportunity / Billing Price Money attributes. No FX feature — the background
# exchange-rate poller stays off.
config :ash, :known_types, [AshMoney.Types.Money]
config :ex_money, auto_start_exchange_rate_service: false

# samen_web is a LIBRARY — in a host app the host owns this config. These entries
# exist ONLY for the standalone test-support host (Samen.WebTest.*), so the framework
# render tests can materialize real scope resources + exercise PiiResolution against a
# scratch repo, with NO dependency on any vertical.

config :samen_web,
  ecto_repos: [Samen.WebTest.Repo]

# NOTE: the test-support host domains (Samen.WebTest.{Crm,Billing,Support}) live in
# test/support and exist ONLY in :test — they are registered as :ash_domains in
# config/test.exs, not here, so a dev/prod compile of this LIBRARY does not try to verify
# domains that aren't loaded.

config :ash, disable_async?: true

config :samen_web, Samen.WebTest.Repo,
  migration_primary_key: [name: :id, type: :binary_id]

# Wire the test repo into every samen_core repo seam PiiResolution/vault need. Mirrors
# driftwood/config/config.exs so the tenant-clear / operator-masked resolution paths
# behave identically against the samen_web scratch DB.
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, Samen.WebTest.Repo
config :samen_core, :non_pii_repo, Samen.WebTest.Repo
config :samen_core, :verify_repo, Samen.WebTest.Repo
config :samen_core, :vault_repo, Samen.WebTest.Repo
config :samen_core, :impersonation_repo, Samen.WebTest.Repo

# ADR-047 A5: the agent-loop resources back the tenant AgentLive + operator
# AgentHealthLive surfaces, so samen_web's scratch DB carries their tables (the three
# migrations mirror samen_core's test_repo byte-for-byte apart from the module name) and
# the compile_env repo seams point at it. Without this the resources would compile
# against SamenCore.TestRepo and no render test could exercise a real vault-routed
# transcript.
config :samen_core, :samen_ai_agent_run_repo, Samen.WebTest.Repo
config :samen_core, :samen_ai_agent_turn_repo, Samen.WebTest.Repo
config :samen_core, :samen_ai_agent_kill_repo, Samen.WebTest.Repo


config :phoenix, :json_library, Jason

# Oban base config (the vault/erasure machinery references it). Manual in test.
config :samen_core, Oban,
  repo: Samen.WebTest.Repo,
  queues: false,
  plugins: false

import_config "#{config_env()}.exs"
