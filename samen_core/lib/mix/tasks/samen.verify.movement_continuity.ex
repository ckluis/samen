defmodule Mix.Tasks.Samen.Verify.MovementContinuity do
  @shortdoc "Fail build when the subscription movement (mov) ledger has a gap or a broken chain."

  @moduledoc """
  `mix samen.verify.movement_continuity` — does each subscription's `mov` ledger chain, and end at
  its live MRR? (kernel phase C review, S4.)

  `Samen.Billing.SubscriptionMovement` is best-effort and, when a price read or an append fails, writes
  no row (and reports). This verifier finds the hole that leaves: a row whose `mrr_before_cents` is not
  the previous row's `mrr_after_cents`, a first row that does not start from 0, a last `mrr_after_cents`
  that is not the subscription's current MRR, or a revenue-active subscription with no row. The engine
  is `Samen.Billing.MovementContinuity`.

  ## Report only

  There is no `--fix`. A gap is a revenue history decision (re-derive, backfill, or accept), not a
  silent repair; `Samen.Billing.MovementBackfill.from_snapshot/1` seeds an unseeded subscription.

  ## Output

  Subscription id, class and cents only — never a name or a customer.

  ## Discovery (fail-closed)

  Subscription resources are the host's resources (`:ash_domains`) that carry the
  `Samen.Billing.SubscriptionMovement` change; its `:event_resource` and `:price_resource` options name
  the ledger and the price source. Zero such resources, or a change without both options, exits 1
  rather than pass over nothing. An empty ledger over existing subscriptions is clean.

  ## Exit code

  0 when clean, 1 on any finding (`:erlang.halt/1`).
  """

  use Mix.Task

  alias Samen.Billing.{MovementContinuity, SubscriptionMovement}

  @task_name "samen.verify.movement_continuity"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    ensure_repos_started!()

    case targets(discover_resources()) do
      [] ->
        IO.puts("")
        IO.puts("FAIL: #{@task_name} discovered no resource carrying the SubscriptionMovement change " <>
                  "(with :event_resource and :price_resource) — a vacuous check must not pass (fail-closed).")
        IO.puts("")
        :erlang.halt(1)

      targets ->
        Samen.Verifier.halt_if_violations(@task_name, Enum.flat_map(targets, &MovementContinuity.violations/1))
    end
  end

  @doc """
  The `MovementContinuity` option lists for every resource in `resources` that carries the
  `SubscriptionMovement` change with both `:event_resource` and `:price_resource`.
  """
  def targets(resources) do
    Enum.flat_map(resources, fn resource ->
      resource
      |> Ash.Resource.Info.changes()
      |> Enum.map(& &1.change)
      |> Enum.flat_map(fn
        {SubscriptionMovement, opts} ->
          with event when not is_nil(event) <- Keyword.get(opts, :event_resource),
               price when not is_nil(price) <- Keyword.get(opts, :price_resource) do
            [[subscription_resource: resource, event_resource: event, price_resource: price]]
          else
            _ -> []
          end

        _ ->
          []
      end)
    end)
  end

  defp ensure_repos_started! do
    for repo <- Application.get_env(Mix.Project.config()[:app], :ecto_repos, []) do
      case repo.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> raise "Could not start repo #{inspect(repo)}: #{inspect(reason)}"
      end
    end
  end

  defp discover_resources do
    otp_app = Mix.Project.config()[:app]

    domains =
      Application.get_env(otp_app, :ash_domains, []) ++
        Samen.HostDomains.registry() ++
        Application.get_env(:ash, :domains, [])

    Samen.Catalog.resource_modules(Enum.uniq(domains))
  end
end
