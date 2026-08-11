defmodule Samen.Jobs.QueueParity do
  @moduledoc """
  Worker-queue ⊆ configured-queue PARITY — the B-OBAN structural guard.

  ## The failure this exists to make impossible

  An Oban job enqueued to a queue that no producer is configured for does not
  fail. `Oban.insert/2` returns `{:ok, job}`, the row lands in `oban_jobs` with
  `state = 'available'`, and then nothing ever claims it. There is no error, no
  retry, no discard, no DLQ entry — Oban reports perfect health because nothing
  was ever attempted. The caller (a webhook ingress that already answered 200 to
  the upstream provider, an operator clicking "replay" on the DLQ, an AshOban
  due-scan) is told it worked.

  That is precisely what shipped: `:webhooks_in` was named by
  `Samen.Webhook.IngestWorker` and configured by ZERO of the four host configs;
  `:automation`/`:automation_timers` were named by the automation, outreach and
  approvals-escalation triggers and configured by ONE. Four hand-maintained
  `queues:` lists had drifted from the taxonomy and nothing compared them.

  The old taxonomy test could not catch it: it asserted a HARD-CODED list of "six
  canonical queues" against `Samen.Jobs.default_queue_config/0` — a list that
  itself omitted `webhooks_in`. It compared the docs to the docs.

  ## What this module does instead

  It DISCOVERS the enqueued-to queues instead of restating them. Every worker
  Samen ships — hand-written (`use Oban.Worker, queue: :webhooks_in`) and
  AshOban-GENERATED (each `trigger`'s worker AND scheduler module is created by
  `AshOban.Transformers.DefineSchedulers` with `use Oban.Worker, queue: ...`) —
  exposes its options through the `c:Oban.Worker.__opts__/0` callback. So the
  authoritative answer to "which queues does this codebase enqueue to?" is read
  off the COMPILED modules of the running app tree, not off a list somebody has
  to remember to update.

  `check/1` then asserts that set is contained in the RESOLVED runtime Oban
  configuration — `Samen.Jobs.install_defaults/1` applied to the host's
  `config :samen_core, Oban`, i.e. byte-for-byte the option list `application.ex`
  hands to the `{Oban, _}` child spec.

  ## Non-vacuity (the A2/X9 lesson)

  Discovery-based verifiers fail OPEN by default: if the discovery step returns
  nothing, "everything discovered is configured" is trivially true and the gate
  passes while checking nothing. `check/1` therefore FAILS CLOSED on empty
  discovery (`{:error, {:no_workers_discovered, apps}}`) and reports the module
  that named each queue, so a green result is always backed by a non-empty,
  attributable sample. `Samen.Jobs.QueueParityTest` additionally pins a floor on
  the discovered population and proves both discovery paths (hand-written worker
  AND AshOban-generated trigger worker) are live.

  ## Scope

  `samen_apps/0` returns the loaded OTP applications that are `:samen_core` or
  depend on it — the framework plus whatever host/verticals are in this release.
  Running under `samen_core` that is the kernel + its test fixtures; running
  under `driftwood` it additionally covers `samen_web` and driftwood itself; in a
  generated app it covers the generated app. Each gate therefore checks its own
  runtime population against its own resolved config.
  """

  @doc """
  The loaded OTP applications built on samen_core (including samen_core itself).
  """
  @spec samen_apps() :: [atom()]
  def samen_apps do
    Application.loaded_applications()
    |> Enum.map(fn {app, _desc, _vsn} -> app end)
    |> Enum.filter(fn app ->
      app == :samen_core or :samen_core in (Application.spec(app, :applications) || [])
    end)
    |> Enum.sort()
  end

  @doc """
  Discover every queue enqueued to by a compiled `Oban.Worker` in `apps`.

  Returns `%{queue_name => [worker_module, ...]}`. Covers hand-written workers and
  AshOban-generated trigger worker/scheduler modules alike, because both are real
  `Oban.Worker` modules exposing `__opts__/0`.

  ## Options

    * `:apps` — the OTP applications to scan (default: `samen_apps/0`)
  """
  @spec discover(keyword()) :: %{atom() => [module()]}
  def discover(opts \\ []) do
    apps = Keyword.get_lazy(opts, :apps, &samen_apps/0)

    for app <- apps,
        mod <- Application.spec(app, :modules) || [],
        {:ok, queue} <- [worker_queue(mod)],
        reduce: %{} do
      acc -> Map.update(acc, queue, [mod], &[mod | &1])
    end
    |> Map.new(fn {queue, mods} -> {queue, Enum.sort(mods)} end)
  end

  @doc """
  The resolved runtime Oban queue names — what `application.ex` actually starts.

  Applies the framework seam (`Samen.Jobs.install_defaults/1`) to the host's
  `config :samen_core, Oban`, exactly as every shipped `application.ex` and the
  generated `application_ex*.eex` templates do, then reads the queue names off
  the result.

  Returns `{:ok, [queue_name]}`, or `{:ok, :disabled}` when the host explicitly
  declared `queues: false` (a deliberate "this node runs no producers" topology —
  see `Samen.Jobs.install_default_queues/1`), or `{:error, :no_oban_config}` when
  the host configured no Oban at all.
  """
  @spec configured_queues(keyword() | nil) :: {:ok, [atom()] | :disabled} | {:error, :no_oban_config}
  def configured_queues(oban_opts \\ nil) do
    case oban_opts || Application.get_env(:samen_core, Oban) do
      nil ->
        {:error, :no_oban_config}

      opts when is_list(opts) ->
        case Samen.Jobs.install_defaults(opts)[:queues] do
          false -> {:ok, :disabled}
          queues when is_list(queues) -> {:ok, Keyword.keys(queues)}
          _ -> {:error, :no_oban_config}
        end
    end
  end

  @doc """
  Assert worker-queue ⊆ configured-queue parity.

  Returns `{:ok, report}` on success, where `report` is a map with `:discovered`
  (sorted queue names), `:configured` (sorted queue names or `:disabled`),
  `:sources` (`queue => [module]`) and `:apps`.

  Fails with:

    * `{:error, {:no_workers_discovered, apps}}` — discovery came back EMPTY. Not
      a pass: a verifier that discovered nothing has verified nothing.
    * `{:error, {:unconfigured_queues, [{queue, [module]}], report}}` — at least one
      queue is enqueued to but has no producer configured. Jobs on it would sit
      `available` forever, silently.
    * `{:error, :no_oban_config}` — no `config :samen_core, Oban` to check against.

  ## Options

    * `:apps` — passed through to `discover/1`
    * `:oban_opts` — the raw host Oban options (default: `config :samen_core, Oban`)
    * `:configured` — the configured queue names to check against, bypassing config
      resolution entirely (`false` for a no-producer node). This is what makes the
      containment predicate REFUTABLE in a unit test: hand it a deliberately short
      list and the check must name every gap, proving it is not a tautology.
  """
  @spec check(keyword()) ::
          {:ok, map()}
          | {:error,
             :no_oban_config
             | {:no_workers_discovered, [atom()]}
             | {:unconfigured_queues, [{atom(), [module()]}], map()}}
  def check(opts \\ []) do
    apps = Keyword.get_lazy(opts, :apps, &samen_apps/0)
    sources = discover(apps: apps)

    if sources == %{} do
      # Fail CLOSED: containment over an empty set is trivially true, so an empty
      # discovery is a broken verifier, never a green one.
      {:error, {:no_workers_discovered, apps}}
    else
      with {:ok, configured} <- resolve_configured(opts) do
        report = %{
          apps: apps,
          discovered: sources |> Map.keys() |> Enum.sort(),
          configured: if(configured == :disabled, do: :disabled, else: Enum.sort(configured)),
          sources: sources
        }

        case unconfigured(sources, configured) do
          [] -> {:ok, report}
          missing -> {:error, {:unconfigured_queues, missing, report}}
        end
      end
    end
  end

  defp resolve_configured(opts) do
    case Keyword.fetch(opts, :configured) do
      {:ok, false} -> {:ok, :disabled}
      {:ok, names} when is_list(names) -> {:ok, names}
      :error -> configured_queues(Keyword.get(opts, :oban_opts))
    end
  end

  # `queues: false` is an explicit no-producer topology, not a drifted list: the
  # node runs no queues at all, deliberately, and the parity question is moot.
  defp unconfigured(_sources, :disabled), do: []

  defp unconfigured(sources, configured) do
    sources
    |> Enum.reject(fn {queue, _mods} -> queue in configured end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # A module contributes a queue iff it is a real Oban.Worker (behaviour attribute
  # present) exposing the `__opts__/0` callback with a `:queue`. Anything else —
  # including modules that merely mention Oban — is ignored.
  defp worker_queue(mod) do
    with true <- Code.ensure_loaded?(mod),
         true <- function_exported?(mod, :__opts__, 0),
         true <- Oban.Worker in behaviours(mod),
         queue when not is_nil(queue) <- mod.__opts__()[:queue] do
      {:ok, normalize(queue)}
    else
      _ -> :error
    end
  rescue
    # A module whose __opts__/0 raises is not a usable worker; never let a single
    # odd module turn the whole gate into a crash (or, worse, an empty pass).
    _ -> :error
  end

  defp behaviours(mod) do
    mod.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp normalize(queue) when is_atom(queue), do: queue
  defp normalize(queue) when is_binary(queue), do: String.to_atom(queue)
end
