defmodule Mix.Tasks.Samen.Verify.RevealOrgs do
  @shortdoc "NOTE the pending reveal requests that carry no org and no approval (nothing can recover them)."

  @moduledoc """
  `mix samen.verify.reveal_orgs` — the reveal-request org NOTE (S6).

  A `RevealRequest` carries the org its engine approval is filed under (`rvq_org_id`); the tenant approver queue
  re-opens a missing approval for the requests of the org it reads. A request with NO org (a row from before the
  column that had no engine approval to take its org from, or one filed without an org) and no plane-global approval
  is invisible to every org's queue. The migration never guesses an org for it, so this task NAMES it.

  It is a NOTE, not a violation: exit 0 either way (the rows are real data a person must look at, not a defect of the
  tree). A read that cannot run is a violation (exit 1): "none found" is never printed for a scan that did not happen.

  Usage: `mix samen.verify.reveal_orgs` (the host's DB must be migrated and `:reveal_grant_repo` configured).
  """
  use Mix.Task

  @task_name "samen.verify.reveal_orgs"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Samen.Reveal.Grants.unattributed_requests() do
      {:ok, []} ->
        Mix.shell().info("#{@task_name}: OK (no pending reveal request without an org and an approval)")

      {:ok, ids} ->
        Mix.shell().info(
          "#{@task_name}: NOTE #{length(ids)} pending reveal request(s) carry no org and have no engine approval; " <>
            "no queue can recover them (ids: #{Enum.join(ids, ", ")})"
        )

      {:error, :unavailable} ->
        IO.puts("")
        IO.puts("FAIL: #{@task_name} could not read the pending reveal requests — an unreadable check must not pass (fail-closed).")
        IO.puts("")
        :erlang.halt(1)
    end
  end
end
