import Config

config :demo, Demo.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "demo_dev"

config :logger, level: :debug
