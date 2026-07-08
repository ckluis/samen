import Config

# PawChart — the Phase-6 second-vertical thin slice (T6.2), the reuse-measurement
# probe. MOUNTS the samen_core Billing scope AS-IS (plain subscriptions, NO reshape),
# AUTHORS the vertical Clinical resources (Patient / Pet), and DEFINES a Tier-2
# VaccineLot custom object clinics author themselves.
config :pawchart,
  ecto_repos: [PawChart.Repo],
  ash_domains: [
    PawChart.Crm,
    PawChart.Billing,
    PawChart.Support,
    PawChart.Marketing,
    PawChart.Clinic,
    PawChart.Aggregate
  ]

# The samen_core verifiers (catalog_parity/prefixes/pii_reads/pii_classify/…) discover
# domains from :samen_core :ash_domains. Register PawChart's domains so the gate scans
# the mounted CRM/Billing/Support scopes + the vertical Clinical resources + the
# token-blind aggregate plane.
config :samen_core, :ash_domains, [
  PawChart.Crm,
  PawChart.Billing,
  PawChart.Support,
  PawChart.Marketing,
  PawChart.Clinic,
  PawChart.Aggregate
]

config :ash, disable_async?: true

config :pawchart, PawChart.Repo,
  migration_primary_key: [name: :id, type: :binary_id]

# Reveal-grant + non_pii + verify + vault + tnt_record repos: wire the PawChart repo.
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, PawChart.Repo
config :samen_core, :non_pii_repo, PawChart.Repo
config :samen_core, :verify_repo, PawChart.Repo
config :samen_core, :vault_repo, PawChart.Repo

# T3.9 Tier-2 custom objects (VaccineLot): the repo backing the tnt_object / tnt_field
# catalog and the tnt_record CRUD. PawChart is the vision doc's canonical Tier-2 case
# ("a VaccineLot object clinics define themselves"), so it wires the tnt_record repo.
config :samen_core, :tnt_record_repo, PawChart.Repo

# T4.5 aggregate-privacy floors for PawChart's token-blind cross-tenant plane. The
# samen_core defaults are k=5 / l=2; the dogfood datasets are small, so — exactly as
# demo/driftwood do — PawChart uses a small-but-non-trivial floor (k=2 / l=2): a
# count-of-one clinic still suppresses (the load-bearing k-anon guarantee that one
# clinic's exact patient volume / MRR is never released). Production hosts keep k=5.
config :samen_core, :k_anonymity_min_cohort, 2
config :samen_core, :l_diversity_min_distinct, 2

# The query-budget ledger repo (SCAFFOLD — accounting only, WARN-not-enforce).
config :samen_core, :query_budget_ledger_repo, PawChart.Repo

config :phoenix, :json_library, Jason

# PawChartWeb.Endpoint — serves the tenant + operator LiveView planes (CRM/Billing/
# Support modules mounted from samen_web + the clinical-vertical pages). Port 4032.
config :pawchart, PawChartWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4032")],
  secret_key_base: "pawchart_local_dogfood_secret_key_base_at_least_64_bytes_long_00000000",
  live_view: [signing_salt: "pawchart_lv_salt_dogfood"],
  render_errors: [formats: [html: PawChartWeb.ErrorHTML], layout: false],
  pubsub_server: PawChart.PubSub,
  server: false

# Oban: the canonical queue taxonomy (reused verbatim from the substrate convention).
config :samen_core, Oban,
  repo: PawChart.Repo,
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
