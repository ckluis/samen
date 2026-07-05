import Config

config :samen_core, SamenCore.TestRepo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_core_dev",
  pool_size: 10
