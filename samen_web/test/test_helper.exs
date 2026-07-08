ExUnit.start()

# Start the scratch repo for the render tests. `mix samen_web.test_setup` (run by the test
# alias) has already created + migrated samen_web_test; it may also have left the repo
# started in the same VM, so tolerate `already_started`.
case Samen.WebTest.Repo.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

Ecto.Adapters.SQL.Sandbox.mode(Samen.WebTest.Repo, :manual)
