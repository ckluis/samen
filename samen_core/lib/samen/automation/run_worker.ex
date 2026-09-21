defmodule Samen.Automation.RunWorker do
  @moduledoc """
  E1 per-run execution (ADR-039 §3.3, §4.4-§4.6). One job = one (workflow, event)
  pair. Oban-**unique** on `{workflow_id, event_id}` (§4.6 tier 1): a retried dispatch
  cannot double-run. Queue `:automation`, `max_attempts 3`.

  Pipeline (ADR-039 §3.3):

    1. **Kill-switch re-check** (§8.4, the already-queued half) — a run of a
       paused/killed workflow finalizes `:skipped`, never fires.
    2. **Owner resolution** (§4.5) — the run executes AS the workflow owner; a removed
       owner ⇒ `:owner_unavailable`, never silently re-attributed.
    3. **Governed subject re-read** — the subject is re-read fresh (never the envelope,
       which carries no values). The subject map handed to the evaluator contains
       ONLY condition-eligible attributes (the §4.4 oracle) — a vault field
       structurally cannot reach `Condition.matches?/2` (INV-1, the read-side twin of
       the write-side `NonPiiPredicates` refusal).
    4. **Condition AND-gate** (§4.4) — `invalid_conditions` (a stored condition failed
       to parse) or unmet conditions ⇒ `:skipped`; else the actions run.
    5. **Compile → Reactor.run** (§5) — outcomes recorded per action.

  ## The definition is PINNED; the guards are LIVE (T162)

  Steps 4 and 5 run the definition **pinned into the job args at enqueue**
  (`Samen.Automation.Definition`), not a fresh read of the Workflow row. Before
  T162 this worker re-read the rule at perform time and executed whatever it found,
  so a tenant edit landing while the run sat queued — or between retries of this
  same job — changed what an already-triggered run did, and the Run row could not be
  interpreted against the definition that actually ran.

  Steps 1-3 are deliberately NOT pinned and still read the live row: the two
  kill-switches (§8.4 — a workflow paused or operator-killed after enqueue must
  still skip), the owner (§4.5) and the governed subject re-read (§3.3). Pinning the
  right to execute would be a worse bug than the one pinning fixes.

  T39 asserted these outcomes via the action side-effect (the notify record);
  T42 adds the durable `Automation.Run` rows + `dispatch_key` (tier 2) — EVERY
  branch below now finalizes a Run row before returning `:ok` (ADR-039 §8.1
  "records EVERY dispatch outcome"), via `Samen.Automation.RunRecord`. Recording
  is deliberately fail-safe (never raises, never blocks the pipeline) — an
  unwired/broken observability layer must never turn an automation execution
  failure into a Run row failure or vice versa.

  After every terminal outcome, `Samen.Automation.Breaker` (§4.7 guard 3) checks
  this workflow's run rate and auto-trips the operator kill-switch past the
  configured runs/minute threshold.
  """
  use Oban.Worker,
    queue: :automation,
    max_attempts: 3,
    unique: [keys: [:workflow_id, :event_id], period: 300, states: Oban.Job.states()]

  require Logger
  import Ash.Query

  alias Samen.Automation

  alias Samen.Automation.{
    Breaker,
    Compile,
    Condition,
    Context,
    Definition,
    NonPiiPredicates,
    RunRecord
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case Automation.workflow_module() do
      nil -> :ok
      workflow_mod -> run(workflow_mod, args)
    end
  end

  defp run(workflow_mod, args) do
    case load_workflow(workflow_mod, args["workflow_id"]) do
      {:ok, wf} ->
        # T162. The workflow row is still loaded — but ONLY for the live checks
        # (kill-switch, owner, org). What this run EXECUTES is the definition
        # pinned into the job args at enqueue, so an edit landing in the queue (or
        # between retries of this same job) cannot change it.
        {_source, definition} = Definition.resolve(args, wf)

        run_row = RunRecord.open!(wf, args)
        result = execute(wf, definition, args, run_row)
        Breaker.check!(wf)
        result

      {:skip, reason} ->
        # No workflow context to attribute a Run row to (missing id / already
        # deleted) — not in the ADR-039 §8.1 bounded reason set, so this stays
        # a log line only, exactly as before T42.
        Logger.debug("[Automation.RunWorker] workflow #{args["workflow_id"]} skipped: #{reason}")
        :ok

      {:error, reason} ->
        Logger.warning("[Automation.RunWorker] workflow #{args["workflow_id"]} error: #{inspect(reason)}")
        :ok
    end
  end

  # `wf` is the LIVE row (kill-switch, owner, org — ADR-039 §8.4/§4.5); `definition`
  # is the PINNED rule (conditions + actions + resource_key — T162). Keeping them as
  # two separate arguments is deliberate: it is what stops a later edit here from
  # quietly reading `wf.actions` again.
  defp execute(wf, definition, args, run_row) do
    with :ok <- kill_switch(wf),
         {:ok, owner} <- owner_actor(wf),
         {:ok, subject_map} <- reread_subject(definition, args),
         :ok <- conditions_gate(definition, subject_map, args) do
      fire(wf, definition, subject_map, owner, args, run_row)
    else
      # kill_switch/owner_actor/reread_subject/conditions_gate only ever
      # produce {:skip, reason} — no `{:error, _}` branch here (would be
      # provably-dead code; the type checker with --warnings-as-errors
      # correctly refuses it). `RunRecord.skip!/2` degrades any reason not in
      # Run's bounded `error_kind` set to `:action_failed` defensively.
      {:skip, reason} ->
        RunRecord.skip!(run_row, reason)
        Logger.debug("[Automation.RunWorker] workflow #{args["workflow_id"]} skipped: #{reason}")
        :ok
    end
  end

  # ---------------------------------------------------------------------------

  defp load_workflow(_mod, nil), do: {:skip, :no_workflow_id}

  defp load_workflow(mod, wid) do
    mod
    |> filter(id == ^wid)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.read!(authorize?: false)
    |> case do
      [wf | _] -> {:ok, wf}
      [] -> {:skip, :workflow_gone}
    end
  rescue
    e -> {:error, e}
  end

  # ADR-039 §8.4 double-check: active AND not operator-killed.
  defp kill_switch(%{status: :active, disabled_by_operator_at: nil}), do: :ok
  defp kill_switch(_wf), do: {:skip, :killed}

  defp owner_actor(%{owner_id: nil}), do: {:skip, :owner_unavailable}

  defp owner_actor(%{owner_id: owner_id, org_id: org_id}) do
    {:ok, Samen.Scope.new(%{id: owner_id, org_id: org_id, role: :member})}
  end

  # Governed re-read, projected to condition-eligible attributes ONLY. A schedule /
  # manual trigger with no subject record yields an empty subject map.
  defp reread_subject(definition, args) do
    record_id = args["record_id"]
    resource_key = args["resource_key"] || Definition.resource_key(definition)

    cond do
      is_nil(record_id) or is_nil(resource_key) ->
        {:ok, %{}}

      true ->
        with {:ok, resource} <- resolve_resource(resource_key),
             {:ok, eligible} <- NonPiiPredicates.eligible_names(resource_key) do
          {:ok, load_eligible(resource, record_id, eligible)}
        else
          _ -> {:ok, %{}}
        end
    end
  end

  defp load_eligible(resource, record_id, eligible) do
    eligible_atoms =
      eligible
      |> MapSet.to_list()
      |> Enum.map(&safe_atom/1)
      |> Enum.reject(&is_nil/1)

    resource
    |> filter(id == ^record_id)
    |> Ash.Query.ensure_selected(eligible_atoms)
    |> Ash.read!(authorize?: false)
    |> case do
      [record | _] -> Map.take(record, eligible_atoms)
      [] -> %{}
    end
  rescue
    _ -> %{}
  end

  defp conditions_gate(definition, subject_map, args) do
    conditions = Definition.conditions(definition)

    cond do
      not Condition.valid?(conditions) ->
        # A stored condition failed to parse — never fire on fewer gates than authored.
        {:skip, :invalid_conditions}

      Condition.all_match?(Condition.parse(conditions), subject_map, args["changed"] || []) ->
        :ok

      true ->
        {:skip, :conditions_unmet}
    end
  end

  defp fire(wf, definition, subject_map, owner, args, run_row) do
    run_row = RunRecord.mark_running!(run_row)

    ctx = %Context{
      org_id: wf.org_id,
      workflow_id: to_string(wf.id),
      subject_ref: args["subject_ref"] || derive_ref(wf, args),
      subject: subject_map,
      actor: owner,
      event: args["event"],
      # T40 additions: the record-mutation family locates + re-fetches the
      # SUBJECT via resource_key/record_id (never the envelope's values — there
      # are none); the webhook action signs with webhook_secret and stamps a
      # stable delivery_id from event_id. All four are read-only carries, never
      # re-derived or bypassed downstream.
      resource_key: args["resource_key"] || Definition.resource_key(definition),
      record_id: args["record_id"],
      event_id: args["event_id"],
      webhook_secret: Map.get(wf, :webhook_secret),
      depth: args["depth"] || 0,
      chain: List.wrap(args["chain"] || [])
    }

    # T162: the PINNED actions, never `wf.actions` — `wf` is the row as it looks
    # NOW, which is exactly what must not decide what an already-triggered run does.
    case Compile.run(Definition.actions(definition), ctx) do
      {:ok, outcomes} ->
        RunRecord.succeed!(run_row, outcomes)
        Logger.debug("[Automation.RunWorker] workflow #{wf.id} fired: #{inspect(outcomes)}")
        :ok

      {:error, reason} ->
        {outcomes, error_kind} = extract_failure(reason)
        RunRecord.fail!(run_row, outcomes, error_kind)
        Logger.warning("[Automation.RunWorker] workflow #{wf.id} action(s) failed: #{inspect(reason)}")
        :ok
    end
  end

  # `Compile.run/2` deliberately does not commit to one error shape (it passes
  # Reactor's own step-error propagation through verbatim — LIVE-CONFIRMED
  # shape: `%Reactor.Error.Invalid{errors: [%Reactor.Error.Invalid.RunStepError{
  # error: <the bounded map ActionStep returned>, step: %Reactor.Step{arguments:
  # [... the FULL Context, including webhook_secret ...]}}]}`). This extraction
  # is DEFENSIVE and conservative by construction: it targets the two Reactor
  # structs BY NAME to reach ONLY their known-safe `.error`/`.errors` field
  # (exactly what `ActionStep.run/3` returned) — it NEVER touches `.step`
  # (which carries the raw step arguments, including `ctx`/`webhook_secret`),
  # never `inspect/1`s or `Exception.message/1`s an unrecognized value into the
  # Run log (that would be exactly the freeform-text leak
  # `Samen.Automation.RunRecord.bounded_outcomes/1` exists to prevent) — any
  # shape this doesn't recognize degrades to `{[], :action_failed}`.
  defp extract_failure(%Reactor.Error.Invalid{errors: errors}) when is_list(errors) do
    errors
    |> Enum.map(&extract_failure/1)
    |> Enum.reduce({[], nil}, fn {outs, kind}, {acc_outs, acc_kind} ->
      {acc_outs ++ outs, acc_kind || kind}
    end)
    |> case do
      {outs, nil} -> {outs, :action_failed}
      {outs, kind} -> {outs, kind}
    end
  end

  defp extract_failure(%Reactor.Error.Invalid.RunStepError{error: inner}), do: extract_failure(inner)

  defp extract_failure({%{} = failed, completed}) when is_list(completed) do
    {Enum.filter(completed, &plain_map?/1) ++ [failed], Map.get(failed, :error_kind, :action_failed)}
  end

  defp extract_failure(%{error_kind: kind} = outcome) when is_map(outcome) do
    if plain_map?(outcome), do: {[outcome], kind}, else: {[], :action_failed}
  end

  defp extract_failure(outcomes) when is_list(outcomes) do
    maps = Enum.filter(outcomes, &plain_map?/1)

    kind =
      case maps do
        [%{error_kind: k} | _] -> k
        _ -> :action_failed
      end

    {maps, kind}
  end

  defp extract_failure(_other), do: {[], :action_failed}

  defp plain_map?(%{__struct__: _}), do: false
  defp plain_map?(m) when is_map(m), do: true
  defp plain_map?(_), do: false

  # ---------------------------------------------------------------------------

  defp resolve_resource(str) when is_binary(str) do
    mod = String.to_existing_atom("Elixir." <> String.trim_leading(str, "Elixir."))
    if Code.ensure_loaded?(mod), do: {:ok, mod}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp resolve_resource(_), do: :error

  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp derive_ref(wf, args) do
    "samen:workflow:#{wf.id}:#{args["event_id"]}"
  end
end
