import Config

config :driftwood, Driftwood.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "driftwood_dev"

# In dev the Endpoint actually serves HTTP (boot + curl dogfood evidence, T5.3 clause (d)).
config :driftwood, DriftwoodWeb.Endpoint, server: true

# Local dev KMS key store (file-backed). Real deploy uses AWS KMS (OPERATOR TODO).
config :samen_core, :kms_key_dir, Path.expand("../priv/dev_keystore", __DIR__)

config :driftwood, Driftwood.Repo, log: false
config :logger, level: :info

# ADR-052 §2.4 — session replay capture is ON in DEV only (demo it at /settings/replays and
# /operator/replays/:org_id), for the orgs whose `samen.replay` flag allows them: `mix
# driftwood.seed` seeds that flag for the Blue Ridge Logistics org. The flag is read from this
# host's Primitives FeatureFlag rows (`flag_opts:` scopes the loader to replay only), and ONLY
# from the operator org's rows (`owner_org_id:` = `:operator_org_id` in config.exs): the flag is
# a platform flag, so a tenant's own `samen.replay` row decides nothing (ADR-052 §2.4.1 item 7).
# prod.exs and test.exs never set `replay:` — capture stays off there. Retention (14 days)
# runs in every env that mounts the replay tables, capture on or off.
config :driftwood, Samen.Observability,
  replay: [
    flag_opts: [
      flag_module: Driftwood.Primitives.FeatureFlag,
      owner_org_id: "0f000000-0000-4000-8000-0000000000aa"
    ]
  ]
