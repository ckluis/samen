import Config

# Driftwood — the Phase-5 freight-brokerage reference vertical (T5.2).
# Mounts the samen_core CRM scope, composes the vertical Freight resources
# (Driver / Settlement / DispatchEvent) and lays Driftwood.Context over the
# kernel nouns (Carrier/Shipper/Load aliases + settlement netting reshape).
config :driftwood,
  ecto_repos: [Driftwood.Repo],
  ash_domains: [Driftwood.Crm, Driftwood.Freight]

# The samen_core verifiers (catalog_parity/prefixes/pii_reads/pii_classify/…)
# discover domains from :samen_core :ash_domains. Register Driftwood's domains so
# the gate scans the mounted CRM scope + the vertical Freight resources.
config :samen_core, :ash_domains, [Driftwood.Crm, Driftwood.Freight]

config :ash, disable_async?: true

config :driftwood, Driftwood.Repo,
  migration_primary_key: [name: :id, type: :binary_id]

# Reveal-grant + non_pii + verify repos (T1.6/T1.7): wire the Driftwood repo.
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, Driftwood.Repo
config :samen_core, :non_pii_repo, Driftwood.Repo
config :samen_core, :verify_repo, Driftwood.Repo
config :samen_core, :vault_repo, Driftwood.Repo

# The FMCSA dispatch gate reads the CDL vault-token PRESENCE (not plaintext) via a
# bounded repo query on the pii_vault table (design §4 / OR-7). It needs the repo.
config :driftwood, :vault_repo, Driftwood.Repo

# Oban: T2.1 canonical queue taxonomy. The load/dispatch workflow (DispatchWorker)
# runs on :default; erasure + reveal keep the shipped queues.
config :samen_core, Oban,
  repo: Driftwood.Repo,
  queues: [
    default: 10,
    rollups: 2,
    webhooks_out: 5,
    erasure: 1,
    maintenance: 1,
    reveal: 5
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

import_config "#{config_env()}.exs"
