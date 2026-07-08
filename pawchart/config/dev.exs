import Config

config :pawchart, PawChart.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "pawchart_dev",
  pool_size: 10

config :logger, level: :info

# In dev the Endpoint actually serves HTTP (boot + curl dogfood evidence).
config :pawchart, PawChartWeb.Endpoint, server: true

# Local dev KMS key store (file-backed).
config :samen_core, :kms_key_dir, Path.expand("../priv/dev_keystore", __DIR__)

config :pawchart, PawChart.Repo, log: false
