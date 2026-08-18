defmodule Samen.AI.Agent.WriteProposal do
  @moduledoc """
  The A4 propose-then-approve seam (ADR-047 §5.3; ADR-043 §6.2 **unamended**) — the ONLY
  door from an agent turn to a mutating governed action, and the E3 approval handler that
  walks through it when a distinct human opens it.

  > *"AI writes do not exist: AI outputs are drafts and proposals … anything with side
  > effects goes through the E3 approvals engine."* — ADR-043 §6.2, which ADR-047 §9#1
  > ratified **unamended** for the agent loop.

  ## The shape (E3 Face 1 — the `Samen.AI.SupportOperator.ReplyHandler` precedent)

  This is a **Face-1 handler registered by kind**, exactly like the T70 AI support-reply
  handler that ADR-043 §6.3 describes — not `Samen.Approvals.Gate` (Face 2), whose change
  face gates *a bounded Ash transition on an existing record with no arguments*. An agent
  tool call is neither: it is an `Samen.Automation.Action` invoked with model-chosen args.
  ADR-047 §5.3 names `Samen.Approvals.Gate` because §5.3 is written in ADR-040 §4's
  vocabulary; the *mechanism* it describes — open an approval, park, distinct human
  decides, execute in the decision transaction, roll everything back on handler error —
  is the Face-1 contract, and it is reused here at ≈0 new engine LOC. Recorded as an
  ADR-047 §10a deviation (row 6).

  ## Wiring (host seam — fail-closed)

      config :samen_core, Samen.Approvals.Registry,
        kinds: %{"ai_agent_write" => {:tenant, Samen.AI.Agent.WriteProposal}}

  An unwired host makes `Samen.Approvals.request/2` refuse `:unregistered_kind`, which the
  loop records as the bounded `:approval_unavailable` tool error and feeds back honestly.
  **A write is never executed because the approval engine was missing** — the failure mode
  of an unwired host is "the agent cannot propose", never "the agent just did it".

  ## Provenance is TOKEN-ONLY (ADR-040 §4.4 / INV-1)

  The approval row carries `{org_id, kind, subject_ref, requested_by, reason, deadline_at,
  state}` and nothing else. Concretely:

    * `kind` — the constant `"ai_agent_write"`;
    * `subject_ref` — `"samen:atn:<turn_id>"`, an object-ref at the `Samen.AI.Agent.Turn`
      row, which is itself token-only by allowlist (ADR-047 §6): `run_id` (arn),
      `turn_index`, `tool_kind`, **arg key NAMES only**, and the validated-args sha256
      **digest** in bounded `meta`;
    * `requested_by` — the AI service principal (below);
    * `reason` — **always `nil`**. Not "usually": passing model text here would be a
      freeform egress into a governed row, and `Samen.PiiReasonScan` is a gate, not a
      licence. `provenance/2` reconstructs the human-meaningful record from governed
      domain state instead — the no-persisted-inputs rule, honoured rather than worked
      around.

  So: **no raw args, no plaintext, no `vt_*` token, ever** — `provenance/2` is the bounded
  view, and the arg VALUES live only inside the run's vault-routed transcript (inside the
  DEK envelope, reached by the run's own 90-day `:shred` retention — ADR-047 §7.4).

  ## Requester ≠ approver, at both layers

  `requested_by` is the **AI service principal** already shipped for the support operator
  (`Samen.AI.SupportOperator.principal_id/0` — ADR-043 §6.3: "a real, auditable identity
  … which holds no reveal grants"). ADR-047 §5.3 says to reuse it, so it is reused rather
  than minted anew. The engine refuses `decided_by == requested_by` at the policy layer
  (`{:error, :self_approval}` + a refusal audit, approval stays pending) AND at the
  `<abbrev>_distinct_party` DB CHECK. The principal is never a decider, and no agent
  surface exposes an approve path.

  ## Execution authority: the APPROVER's, never the agent's

  On approve, `on_approve/2` delegates to `Samen.AI.Agent.execute_approved/3`, which runs
  the governed action as a principal built from `ctx.actor` — the **DECIDING** party (the
  `Samen.Approvals.Handler` contract: "`actor` is the DECIDING actor (the approver)").

  This is the one place A4 departs from ADR-047 §5.3's letter, which — inheriting
  ADR-040 §4.4's Face-2 wording — says the handler re-invokes "as the requester". Here the
  requester is the AI service principal, so executing as the requester would mean an agent
  causing a write to execute **with AI authority**, which is precisely what ADR-043 §6.2
  (binding, unamended, and cited by §5.3 itself) forbids, and precisely what the shipped
  §6.3 precedent avoids: `ReplyHandler` does not send as the AI principal either. ADR-040's
  "requester, not approver" rule exists so an approver cannot *escalate* a human requester
  beyond their own envelope; it is not a licence to grant a machine principal write
  authority. So the AI principal holds NO write authority anywhere, and every agent-caused
  mutation is attributable to the human who consented to it. Recorded as an ADR-047 §10a
  deviation (row 7). `Samen.Approvals.Gate`'s own behaviour is untouched — T34's
  "runs as requester, not approver" property is not weakened by this module.

  ## Fail-honest decisions

  `on_approve/2` returning `{:error, _}` rolls the WHOLE decision back: the approval stays
  `pending`, the run stays parked, nothing executed, no audit lands. That covers the
  digest-binding refusal, a tool de-registered between proposal and approval, and a
  genuine tool failure alike — an approver who approved X and got nothing sees an error
  and an approval they can retry or reject, never a consumed approval with no effect.
  """

  @behaviour Samen.Approvals.Handler

  alias Samen.AI.Agent.Turn

  @kind "ai_agent_write"

  # ADR-047 §10 defers "the deadline default" to A4. 24h: long enough that a proposal
  # raised outside working hours survives to be seen, short enough that a stale proposal
  # does not sit against a record indefinitely. Host-overridable.
  @default_deadline_seconds 86_400

  @doc "The single registered E3 kind for every agent-proposed write (§10, decided at A4)."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  The requester identity on every agent write proposal: the AI service principal shipped
  for the support operator (ADR-043 §6.3; ADR-047 §5.3 says to reuse it). It holds no
  reveal grants, is never a decider, and — by this module's design — never executes a
  write either.
  """
  @spec requester_principal_id() :: String.t()
  def requester_principal_id, do: Samen.AI.SupportOperator.principal_id()

  @doc "The proposal deadline window in seconds (host-configurable)."
  @spec deadline_seconds() :: pos_integer()
  def deadline_seconds do
    case Application.get_env(:samen_core, __MODULE__, [])[:deadline_seconds] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_deadline_seconds
    end
  end

  @doc "The object-ref the approval hangs on: the `{run_id, turn_index}` turn row."
  @spec subject_ref(String.t()) :: String.t()
  def subject_ref(turn_id) when is_binary(turn_id), do: "samen:atn:" <> turn_id

  @doc """
  Open (or return the existing pending) approval for a proposed write. Idempotent per
  `{org_id, kind, subject_ref}` while pending — the engine's own partial unique index —
  so a replay of the same turn row proposes ONCE.

  Returns `{:ok, approval}` or `{:error, reason}`; every failure (unwired engine,
  unregistered kind, write failure) is surfaced to the loop as a bounded
  `:approval_unavailable` tool error, never swallowed into a silent execution.
  """
  @spec open(map()) :: {:ok, struct()} | {:error, term()}
  def open(%{org_id: org_id, turn_id: turn_id} = proposal)
      when is_binary(org_id) and is_binary(turn_id) do
    Samen.Approvals.request(%{
      org_id: org_id,
      kind: @kind,
      subject_ref: subject_ref(turn_id),
      requested_by: requester_principal_id(),
      reason: proposal_reason(proposal),
      deadline_at:
        DateTime.utc_now() |> DateTime.add(deadline_seconds()) |> DateTime.truncate(:second)
    })
  end

  def open(_attrs), do: {:error, :invalid_proposal}

  # THE reason slot, and what this module decides to put in it: NOTHING.
  #
  # The caller hands the whole proposal — tool kind AND validated arg values — so the
  # choice is explicit rather than an accident of what happened to be in scope. An
  # approval row is `{org_id, kind, subject_ref, parties, reason, state}` and the engine
  # NEVER stores an action's inputs (ADR-040 §4.4, INV-1): the arg values live only inside
  # the run's vault-routed transcript, and `provenance/2` re-derives everything a reviewer
  # needs from governed domain state. `Samen.PiiReasonScan` gates this field at write, but
  # a gate is not a licence — a `reason` carrying arg values would be raw proposal input
  # persisted in a governed row, in plaintext, outside the DEK envelope. Sabotage 253 puts
  # them there and the named token-only-provenance test flips.
  defp proposal_reason(_proposal), do: nil

  @doc """
  The bounded, TOKEN-ONLY provenance of a proposal, re-derived from governed domain state
  (never from the approval row, which stores no inputs): `run_id` (arn), `turn_index`,
  `tool_kind`, `arg_keys` (NAMES only), and the validated-args sha256 `args_digest`.

  This is what a reviewer/approver surface renders. It is deliberately incapable of
  carrying an arg VALUE: every field here is an id, an integer, a registry enum, a list of
  key names, or a hex digest.
  """
  @spec provenance(struct()) :: {:ok, map()} | {:error, term()}
  def provenance(approval) do
    with {:ok, turn_id} <- parse_subject_ref(Map.get(approval, :subject_ref)),
         {:ok, turn} <- fetch_turn(turn_id) do
      {:ok,
       %{
         run_id: to_string(turn.run_id),
         turn_index: turn.turn_index,
         tool_kind: turn.tool_kind,
         arg_keys: turn.arg_keys,
         args_digest: Map.get(turn.meta || %{}, "args_digest")
       }}
    end
  end

  # ==========================================================================
  # The E3 handler faces — both run INSIDE the decision transaction (§4.3).
  # ==========================================================================

  @impl true
  def on_approve(approval, ctx) do
    with {:ok, turn_id} <- parse_subject_ref(approval.subject_ref) do
      Samen.AI.Agent.execute_approved(turn_id, approval, ctx)
    end
  end

  @impl true
  def on_reject(approval, ctx) do
    with {:ok, turn_id} <- parse_subject_ref(approval.subject_ref) do
      Samen.AI.Agent.reject_proposal(turn_id, approval, ctx)
    end
  end

  # ==========================================================================
  # Subject-ref codec + the governed turn read.
  # ==========================================================================

  @doc false
  @spec parse_subject_ref(term()) :: {:ok, String.t()} | {:error, term()}
  def parse_subject_ref(ref) when is_binary(ref) do
    case String.split(ref, ":", parts: 3) do
      ["samen", "atn", id] when byte_size(id) > 0 -> {:ok, id}
      _ -> {:error, {:bad_subject_ref, ref}}
    end
  end

  def parse_subject_ref(ref), do: {:error, {:bad_subject_ref, ref}}

  defp fetch_turn(turn_id) do
    require Ash.Query

    Turn
    |> Ash.Query.filter(id == ^turn_id)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [turn]} -> {:ok, turn}
      _ -> {:error, :turn_not_found}
    end
  rescue
    _ -> {:error, :turn_not_found}
  end
end
