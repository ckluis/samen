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

  @doc """
  This org's agent runs, newest first (token-only columns; the transcript is NOT
  selected here — a list does not need it).

  ORG-SCOPE PIN: the `org_id == ^org_id` conjunct comes from the trusted scope. Dropping
  it flips a named cross-org test.
  """
  @spec list(Mount.t(), String.t() | nil, keyword()) :: [map()]
  def list(mount, org_id, opts \\ [])

  def list(_mount, nil, _opts), do: []

  def list(_mount, org_id, opts) do
    Run
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(Keyword.get(opts, :limit, 50))
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, runs} -> runs
      _ -> []
    end
  rescue
    _ -> []
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
  def get(_mount, nil, _run_id), do: {:error, :not_found}

  def get(mount, org_id, run_id) when is_binary(run_id) do
    Run
    |> Ash.Query.filter(org_id == ^org_id and id == ^run_id)
    |> Ash.Query.ensure_selected([:org_id, :transcript])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [run]} ->
        # THE resolution: the actor's plane decides, `Samen.Api.PiiResolution` performs.
        [resolved] =
          Samen.Api.PiiResolution.resolve([run], Run, actor_of(mount, org_id), repo: mount.repo)

        {goal, lines} = decode_transcript(Map.get(resolved, :transcript))
        approval = pending_approval(org_id, run)

        {:ok,
         %{
           run: run,
           goal: goal,
           lines: lines,
           turns: turns(org_id, run.id),
           approval: approval,
           provenance: provenance(approval)
         }}

      _ ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  def get(_mount, _org_id, _run_id), do: {:error, :not_found}

  @doc "The bounded per-turn log for one run (token-only, ADR-047 §6)."
  @spec turns(String.t(), String.t()) :: [map()]
  def turns(org_id, run_id) do
    Turn
    |> Ash.Query.filter(org_id == ^org_id and run_id == ^run_id)
    |> Ash.Query.sort(turn_index: :asc)
    |> Ash.Query.limit(100)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, turns} -> turns
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  The PENDING `ai_agent_write` approval for a parked run, or `nil`. Matched by the
  approval's `subject_ref` against this run's own `:proposed` turn row, so a pending
  approval belonging to a different run can never be rendered on this run's card (and
  therefore can never be decided from it).
  """
  @spec pending_approval(String.t(), map()) :: struct() | nil
  def pending_approval(org_id, %{state: :awaiting_approval} = run) do
    refs =
      org_id
      |> proposed_turn_ids(run.id)
      |> MapSet.new(&WriteProposal.subject_ref/1)

    case Samen.Approvals.list_pending(org_id, WriteProposal.kind()) do
      {:ok, approvals} -> Enum.find(approvals, &MapSet.member?(refs, &1.subject_ref))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def pending_approval(_org_id, _run), do: nil

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
    case Samen.Approvals.approve(approval_id, actor_id) do
      {:ok, decided, meta} -> {:ok, {decided, meta}}
      {:ok, decided} -> {:ok, decided}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :decision_failed}
  end

  def decide(:reject, approval_id, actor_id) when is_binary(approval_id) and is_binary(actor_id) do
    case Samen.Approvals.reject(approval_id, actor_id) do
      {:ok, decided} -> {:ok, decided}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :decision_failed}
  end

  def decide(_action, _approval_id, _actor_id), do: {:error, :not_authorized}

  @doc "Durably request cancellation of a run, through the kernel's own org-scoped `cancel/2`."
  @spec cancel(Mount.t(), String.t() | nil, String.t()) :: {:ok, term()} | {:error, term()}
  def cancel(_mount, nil, _run_id), do: {:error, :not_found}

  def cancel(mount, org_id, run_id) do
    Agent.cancel(Mount.scope(mount, org_id), run_id)
  rescue
    _ -> {:error, :not_found}
  end

  # ---------------------------------------------------------------------------

  defp actor_of(mount, org_id) do
    case Mount.scope(mount, org_id) do
      %Samen.Scope{actor: actor} -> actor
      other -> other
    end
  end

  defp proposed_turn_ids(org_id, run_id) do
    Turn
    |> Ash.Query.filter(org_id == ^org_id and run_id == ^run_id and status == :proposed)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, turns} -> Enum.map(turns, & &1.id)
      _ -> []
    end
  rescue
    _ -> []
  end

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
