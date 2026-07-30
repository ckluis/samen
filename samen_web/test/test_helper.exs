ExUnit.start()

# Start the scratch repo for the render tests. `mix samen_web.test_setup` (run by the test
# alias) has already created + migrated samen_web_test; it may also have left the repo
# started in the same VM, so tolerate `already_started`.
case Samen.WebTest.Repo.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

Ecto.Adapters.SQL.Sandbox.mode(Samen.WebTest.Repo, :manual)

# T41 (ADR-039 §7): the `Samen.WebTest.Automation.Escalation` AshOban due-scan
# trigger needs a running default-named `Oban` instance to insert/drain against
# (readiness_test.exs's red path already proves the "not running" failure mode
# with its OWN isolated named instance; this is the shared default-named one
# every other AshOban-triggered resource in this test suite will use). The
# `:samen_core, Oban` config (repo/queues/plugins/testing) is already wired in
# config/config.exs + config/test.exs — mirrors samen_core/test/test_helper.exs's
# own `Oban.start_link/1` call verbatim.
case Oban.start_link(Application.fetch_env!(:samen_core, Oban)) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
