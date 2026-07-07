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
