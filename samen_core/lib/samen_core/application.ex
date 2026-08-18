defmodule SamenCore.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # The test harness (test/test_helper.exs) owns the Repo lifecycle so it can
    # storage_up + migrate before connections open. A host application supervises
    # its own repo; samen_core ships no runtime repo of its own.
    repo_children =
      if Application.get_env(:samen_core, :start_repo?, false) do
        [SamenCore.TestRepo]
      else
        []
      end

    # The InMemory KMS adapter needs an Agent process for its store.
    # It auto-starts on first use but supervising it here enables clean restarts
    # in test suites that stop the agent to reset state.
    kms_children = [Samen.Kms.InMemory]

    # The feature-flag evaluation cache (ADR-020 §2 decision 4; ETS owner). Like the
    # KMS agent it auto-starts on first use (Cache.get/2 lazily starts the owner),
    # but supervising it here gives a clean restart and a warm table across the suite.
    flag_cache_children = [Samen.FeatureFlags.Cache]

    # Oban (T1.6 same-tx reveal-grant auto-revoke). Only supervise it here when
    # this app also supervises the repo — Oban needs a running repo. The test
    # harness starts the repo itself (start_repo? = false) and starts Oban after
    # migrating, so we skip Oban here in that case (test/test_helper.exs owns it).
    oban_children =
      if Application.get_env(:samen_core, :start_repo?, false) do
        [{Oban, Samen.Jobs.install_defaults(Application.fetch_env!(:samen_core, Oban))}]
      else
        []
      end

    children = kms_children ++ flag_cache_children ++ repo_children ++ oban_children

    Supervisor.start_link(children, strategy: :one_for_one, name: SamenCore.Supervisor)
  end
end
