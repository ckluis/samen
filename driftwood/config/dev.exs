import Config

config :driftwood, Driftwood.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "driftwood_dev"

config :logger, level: :debug
