import Config

config :s02_transformer, S02Transformer.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_spike_s02_dev",
  pool_size: 10
