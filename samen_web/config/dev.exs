import Config

config :samen_web, Samen.WebTest.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_web_dev",
  pool_size: 10
