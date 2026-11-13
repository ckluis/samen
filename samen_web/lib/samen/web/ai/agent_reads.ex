defmodule Samen.Web.AI.AgentReads do
  @moduledoc """
  The TENANT-plane read seam behind `Samen.Web.AI.AgentLive` (ADR-047 A5).

  Every read here is org-scoped from the TRUSTED mount scope (never from params) and
  every vault-routed value is resolved through `Samen.Api.PiiResolution` **on the
  actor's plane** — the one seam every framework read surface runs on. Nothing in this
  module hand-masks, and nothing branches on plane: the resolver is the gate (ADR-042).

  ## The one vault-routed field on this surface

  `Samen.AI.Agent.Run.transcript` (`pii do vault(:pii_transcript) … end`) is the run's
  goal + rendered assistant lines, inside the DEK envelope keyed on the run's own id.
  It is the ONLY 🔒 field the agent surfaces touch, and it is why this surface carries
  MaskingCase three-proofs: tenant plane CLEAR, operator-without-grant `••••` with no
  `vt_*` token in the DOM, and a refutable sabotage twin.

  Note what is deliberately NOT here: no reveal-grant path. ADR-047 §4.4 / §9#2 (TAKEN)
  make an agent run masked-only for EGRESS; for RENDERING, the ordinary two-plane rule
  applies and a grant may unmask an operator's view exactly as it does for any other
  vault-routed field — through `PiiResolution`, never through a bespoke branch. The
  operator OVERSIGHT surface (`Samen.Web.Operator.AgentHealthLive`) does not render the
  transcript at all (§7.3 mask-by-omission), so the two planes never disagree by accident.

  The turn log and the run list are token-only by allowlist (ADR-047 §6) — ids, enums,
  counts, durations, arg key NAMES — so they need no resolution and carry no PII.
  """

  require Ash.Query

  alias Samen.AI.Agent
  alias Samen.AI.Agent.Run
  alias Samen.AI.Agent.Turn
  alias Samen.AI.Agent.WriteProposal
  alias Samen.Web.Mount
  alias Samen.Web.Reads.Guard

  @doc """
  This org's agent runs, newest first (token-only columns; the transcript is NOT
  selected here — a list does not need it).

  ORG-SCOPE PIN: the `org_id == ^org_id` conjunct comes from the trusted scope. Dropping
  it flips a named cross-org test.
  """
  @spec list(Mount.t(), String.t() | nil, keyword()) :: [map()]
  def list(mount, org_id, opts \\ [])

  def list(_mount, nil, _opts), do: []

  def list(mount, org_id, opts), do: list_result(mount, org_id, opts) |> Guard.value([])

  @doc """
  Tagged sibling of `list/3` (WP6): `{:ok, runs}` — an empty list is the honest "no runs yet" —
  or `{:error, :unavailable | :forbidden}` when the read FAILED (an outage is not "No agent runs
  yet").
  """
  @spec list_result(Mount.t(), String.t() | nil, keyword()) :: Guard.result([map()])
  def list_result(mount, org_id, opts \\ [])

  def list_result(_mount, nil, _opts), do: {:ok, []}

  def list_result(_mount, org_id, opts) do
    Guard.run(:ai_agent_runs, org_id, fn ->
      Run
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(Keyword.get(opts, :limit, 50))
      |> Ash.read(authorize?: false)
      |> unwrap!()
    end)
  end

  @doc """
  ONE run, with its transcript RESOLVED on the mount's plane, its bounded turn log, and
  (when parked) the pending write proposal's TOKEN-ONLY provenance + the approval row.

  Returns `{:ok, %{run:, goal:, lines:, turns:, approval:, provenance:}}` or
  `{:error, :not_found}` for a run in another org (a foreign run does not exist —
  RP-AG-10; there is no existence oracle here).

  `goal`/`lines` are whatever the plane resolved: real strings on the tenant plane, and
  the `%Samen.Masked{}` mask on an operator plane without a grant. The template renders
  what it is handed and never decides.
  """
  @spec get(Mount.t(), String.t() | nil, String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(mount, org_id, run_id) do
    case get_result(mount, org_id, run_id) do
      {:ok, detail} -> {:ok, detail}
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Tagged sibling of `get/3` (WP6): `{:ok, detail}`, `{:error, :not_found}` for a missing or
  foreign run, and `{:error, :unavailable}` ONLY when the run read itself FAILED (a failed read
  is not "run not found"). The turn log and the pending approval fail on their own: the detail
  carries `turns_failed` / `approval_failed` flags (a failed approval lookup must not read as "no
  proposal awaiting you").
  """
  @spec get_result(Mount.t(), String.t() | nil, String.t() | nil) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def get_result(_mount, nil, _run_id), do: {:error, :not_found}

  def get_result(mount, org_id, run_id) when is_binary(run_id) do
    case Guard.run(:ai_agent_get_run, org_id, fn ->
           Run
           |> Ash.Query.filter(org_id == ^org_id and id == ^run_id)
           |> Ash.Query.ensure_selected([:org_id, :transcript])
           |> Ash.Query.limit(1)
           |> Ash.read(authorize?: false)
           |> unwrap!()
           |> case do
             [run] ->
               # THE resolution: the actor's plane decides, `Samen.Api.PiiResolution` performs.
               [resolved] =
                 Samen.Api.PiiResolution.resolve([run], Run, actor_of(mount, org_id), repo: mount.repo)

               {run, Map.get(resolved, :transcript)}

             _ ->
               :not_found
           end
         end) do
      {:ok, :not_found} ->
        {:error, :not_found}

      {:ok, {run, transcript}} ->
        {goal, lines} = decode_transcript(transcript)
        approval = pending_approval_result(org_id, run)
        turns = turns_result(org_id, run.id)
        approval_row = Guard.value(approval, nil)

        {:ok,
         %{
           run: run,
           goal: goal,
           lines: lines,
           turns: Guard.value(turns, []),
           turns_failed: Guard.unavailable?(turns),
           approval: approval_row,
           approval_failed: Guard.unavailable?(approval),
           provenance: provenance(approval_row)
         }}

      {:error, :forbidden} ->
        {:error, :not_found}

      {:error, :unavailable} = unavailable ->
        unavailable
    end
  end

  def get_result(_mount, _org_id, _run_id), do: {:error, :not_found}

  @doc "The bounded per-turn log for one run (token-only, ADR-047 §6)."
  @spec turns(String.t(), String.t()) :: [map()]
  def turns(org_id, run_id), do: turns_result(org_id, run_id) |> Guard.value([])

  @doc "Tagged sibling of `turns/2` (WP6): `{:ok, turns}` or `{:error, :unavailable | :forbidden}`."
  @spec turns_result(String.t(), String.t()) :: Guard.result([map()])
  def turns_result(org_id, run_id) do
    Guard.run(:ai_agent_turns, org_id, fn ->
      Turn
      |> Ash.Query.filter(org_id == ^org_id and run_id == ^run_id)
      |> Ash.Query.sort(turn_index: :asc)
      |> Ash.Query.limit(100)
      |> Ash.read(authorize?: false)
      |> unwrap!()
    end)
  end

  @doc """
  The PENDING `ai_agent_write` approval for a parked run, or `nil`. Matched by the
  approval's `subject_ref` against this run's own `:proposed` turn row, so a pending
  approval belonging to a different run can never be rendered on this run's card (and
  therefore can never be decided from it).
  """
  @spec pending_approval(String.t(), map()) :: struct() | nil
  def pending_approval(org_id, run), do: pending_approval_result(org_id, run) |> Guard.value(nil)

  @doc """
  Tagged sibling of `pending_approval/2` (WP6): `{:ok, approval | nil}` (`nil` = honestly no
  proposal pending) or `{:error, :unavailable | :forbidden}` when the lookup FAILED.
  """
  @spec pending_approval_result(String.t(), map()) :: Guard.result(struct() | nil)
  def pending_approval_result(org_id, %{state: :awaiting_approval} = run) do
    Guard.run(:ai_agent_pending_approval, org_id, fn ->
      refs =
        org_id
        |> proposed_turn_ids!(run.id)
        |> MapSet.new(&WriteProposal.subject_ref/1)

      case Samen.Approvals.list_pending(org_id, WriteProposal.kind()) do
        {:ok, approvals} -> Enum.find(approvals, &MapSet.member?(refs, &1.subject_ref))
        # An unwired host has no approvals engine: honestly no pending proposal.
        {:error, :no_approvals_module} -> nil
        {:error, _} -> raise "pending approval read failed"
      end
    end)
  end

  def pending_approval_result(_org_id, _run), do: {:ok, nil}

  @doc "The token-only provenance a reviewer decides on (never an arg VALUE)."
  @spec provenance(struct() | nil) :: map() | nil
  def provenance(nil), do: nil

  def provenance(approval) do
    case WriteProposal.provenance(approval) do
      {:ok, provenance} -> provenance
      _ -> nil
    end
  end

  @doc """
  Decide a pending agent write proposal. This is a THIN pass-through to the REAL
  approvals engine (`Samen.Approvals.approve/3` / `reject/3`) — A5 adds a surface, never
  a second decision path: requester ≠ approver, the `<abbrev>_distinct_party` DB CHECK,
  the digest binding, the approver-membership resolution and the execute-inside-the-
  decision-transaction contract are all the engine's, unchanged.

  `actor_id` is the AUTHENTICATED principal from the trusted scope — never a form field.
  """
  @spec decide(:approve | :reject, String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def decide(:approve, approval_id, actor_id) when is_binary(approval_id) and is_binary(actor_id) do
    # `Guard.write/3`: the engine's own tagged return passes through; a raise is logged by name
    # and cause and becomes `{:error, :unavailable}` (the screen: "could not be completed —
    # nothing was executed"), never an exception term.
    Guard.write(:ai_agent_decide, nil, fn ->
      case Samen.Approvals.approve(approval_id, actor_id) do
        {:ok, decided, meta} -> {:ok, {decided, meta}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def decide(:reject, approval_id, actor_id) when is_binary(approval_id) and is_binary(actor_id) do
    Guard.write(:ai_agent_decide, nil, fn ->
      case Samen.Approvals.reject(approval_id, actor_id) do
        {:ok, decided} -> {:ok, decided}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def decide(_action, _approval_id, _actor_id), do: {:error, :not_authorized}

  @doc "Durably request cancellation of a run, through the kernel's own org-scoped `cancel/2`."
  @spec cancel(Mount.t(), String.t() | nil, String.t()) :: {:ok, term()} | {:error, term()}
  def cancel(_mount, nil, _run_id), do: {:error, :not_found}

  def cancel(mount, org_id, run_id) do
    Guard.write(:ai_agent_cancel, org_id, fn -> Agent.cancel(Mount.scope(mount, org_id), run_id) end)
  end

  # ---------------------------------------------------------------------------

  defp actor_of(mount, org_id) do
    case Mount.scope(mount, org_id) do
      %Samen.Scope{actor: actor} -> actor
      other -> other
    end
  end

  # Raising on purpose: only called inside `pending_approval_result/2`'s `Guard.run/3`.
  defp proposed_turn_ids!(org_id, run_id) do
    Turn
    |> Ash.Query.filter(org_id == ^org_id and run_id == ^run_id and status == :proposed)
    |> Ash.read(authorize?: false)
    |> unwrap!()
    |> Enum.map(& &1.id)
  end

  # An Ash `{:error, _}` return is a FAILED read, not an empty one: raise so the surrounding
  # `Guard.run/3` reports it (the exception is never rendered).
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: raise(Ash.Error.to_error_class(error))

  # The transcript is JSON inside the envelope. On a plane that resolved it CLEAR we get
  # a binary and decode it; on a masked plane we get a `%Samen.Masked{}` and pass THAT
  # through untouched — the template renders `to_string(masked)` == `••••`. There is no
  # hand-mask branch here and no plane check: an unparseable/absent transcript is the
  # same honest "unavailable" either way.
  defp decode_transcript(%Samen.Masked{} = masked), do: {masked, [masked]}

  defp decode_transcript(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"goal" => goal, "lines" => lines}} when is_binary(goal) and is_list(lines) ->
        {goal, Enum.filter(lines, &is_binary/1)}

      _ ->
        {nil, []}
    end
  end

  defp decode_transcript(_other), do: {nil, []}
end
