import Config

# Demo is a contact-manager dogfood app (T1.9).
# It uses samen_core as a path dep and exercises EVERY T1 feature.
config :demo,
  ecto_repos: [Demo.Repo],
  ash_domains: [Demo.Crm]

# samen_core verifiers (C1/C2/C3/C4/C5) discover domains from
# :samen_core :ash_domains. Register the demo's domain here so the
# verifier tasks find the demo resources.
config :samen_core, :ash_domains, [Demo.Crm]

config :ash, disable_async?: true

config :demo, Demo.Repo,
  migration_primary_key: [name: :id, type: :binary_id]

# Reveal-grant model: wire Samen.Reveal.Grants (T1.6).
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, Demo.Repo
config :samen_core, :non_pii_repo, Demo.Repo
config :samen_core, :verify_repo, Demo.Repo

# Oban: T1.6 same-tx auto-revoke enqueue.
config :samen_core, Oban,
  repo: Demo.Repo,
  queues: [reveal: 5],
  plugins: false

import_config "#{config_env()}.exs"
