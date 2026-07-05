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

# catalog_parity allow-list (Gate-1 F3): the cnt_contact table has two raw-DDL
# columns added by migration — cnt_notes (the non_pii! reviewed plaintext column)
# and cnt_subject_id — that are NOT Ash resource attributes, so catalog_sync never
# emitted fld_field rows for them. They are intentional shadow columns, allow-listed
# so C1 catalog_parity does not flag them. This lives in the SHARED config (not
# config/test.exs) so `bash demo/ci.sh` is green in any MIX_ENV, not only :test.
# Keyed under :demo — the verifier reads Application.get_env(Mix.Project.config()[:app], …).
config :demo, :catalog_parity_allow_list, [
  {"cnt_contact", "cnt_notes"},
  {"cnt_contact", "cnt_subject_id"}
]

# Reveal-grant model: wire Samen.Reveal.Grants (T1.6).
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, Demo.Repo
config :samen_core, :non_pii_repo, Demo.Repo
config :samen_core, :verify_repo, Demo.Repo

# Oban: T2.1 canonical queue taxonomy (consolidates T1.6 same-tx reveal enqueue).
# Uses the full Samen.Jobs queue taxonomy per the T2.1 convention layer.
# In production wire cron + pruner plugins; in test override with testing: :manual.
config :samen_core, Oban,
  repo: Demo.Repo,
  queues: [
    default: 10,
    rollups: 2,
    webhooks_out: 5,
    erasure: 1,
    maintenance: 1,
    reveal: 5
  ],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"*/10 * * * *", Samen.Jobs.RollupRefreshWorker}
     ]},
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

import_config "#{config_env()}.exs"
