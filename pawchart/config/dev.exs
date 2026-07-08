import Config

config :pawchart, PawChart.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "pawchart_dev",
  pool_size: 10

config :logger, level: :info
