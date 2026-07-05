import Config

config :s03_fragments, S03Fragments.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_spike_s03_dev",
  pool_size: 10
