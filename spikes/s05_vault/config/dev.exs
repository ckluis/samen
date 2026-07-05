import Config

config :s05_vault, Samen.Repo,
  username: System.get_env("PGUSER", System.get_env("USER", "clank")),
  password: System.get_env("PGPASSWORD", ""),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "samen_spike_s05_dev",
  pool_size: 10
