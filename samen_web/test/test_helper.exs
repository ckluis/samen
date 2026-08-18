# Fresh, per-run FileBacked KMS key store (mirrors samen_core/demo/driftwood/pawchart
# test_helpers). Without this, every samen_web `mix test` run writes subject key
# subdirs into the SHARED `$TMPDIR/samen_core_keystore` (the `Samen.Kms.FileBacked`
# default), accumulating per-subject dirs across runs until that directory hits the
# filesystem's directory link-count ceiling and every vault op fails with
# `{:error, :decrypt_failed}`. Pointing `:samen_core, :kms_key_dir` at a per-run temp
# dir keeps the shared keystore untouched and cleans up on exit. (Test infra only —
# the FileBacked adapter and vault runtime are unchanged; the masking/vault suites
# still write+read+decrypt subject keys, just inside this isolated dir.)
kms_key_dir =
  Path.join(System.tmp_dir!(), "samen_web_keystore_test_#{System.system_time(:nanosecond)}")

File.rm_rf!(kms_key_dir)
Application.put_env(:samen_core, :kms_key_dir, kms_key_dir)
System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)

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

# B-SEC (S5) — the LiveView-driving tenant-authz red-path suite needs a real endpoint.
# `server: false`, so this starts the endpoint's supervision tree (config, pubsub-less)
# without binding a port.
case Samen.WebTest.SecurityEndpoint.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end
