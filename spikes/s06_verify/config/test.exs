import Config

config :s06_verify, S06Verify.Repo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_spike_s06_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :logger, level: :warning

# When MIX_ENV=test the test_helper.exs owns the repo lifecycle (it must call
# storage_up before the repo connects). We set start_repo?: false here so the
# Application supervisor does NOT start the Repo on application start — the
# test_helper starts it explicitly after storage_up.
#
# The System.cmd-based exit-code tests spawn a child mix process in MIX_ENV=test.
# That child runs `Mix.Task.run("app.start")` inside the mix task, which will
# see start_repo?: false and skip the supervised start. The task's run/1 calls
# Repo.start_link!/0 as a fallback so the child process has a working repo.
# See Mix.Tasks.Samen.Verify.CatalogParity.run/1 for the fallback start.
config :s06_verify, start_repo?: false
