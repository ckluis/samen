import Config

config :s06_verify, S06Verify.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_spike_s06_dev"
