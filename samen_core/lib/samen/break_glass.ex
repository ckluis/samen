defmodule Samen.BreakGlass do
  @moduledoc """
  The **break-glass emergency reveal** path (T4.4; doc "honest edges" break-glass
  bullet). A DISTINCT emergency path from the routine `Samen.Reveal` grant flow,
  for the case where the routine path would fail closed because the central audit /
  control-plane DB is unreachable — but an operator still legitimately needs to see
  a subject NOW.

  The doc's spec is precise about what survives what, and this module implements
  exactly that:

    * **Control-plane (central audit DB) down** ⇒ the reveal still COMPLETES. The
      who/what/why is captured to a **locally-durable, fsync'd, append-only,
      hash-chained** record on the operator node's own disk
      (`Samen.BreakGlass.LocalAudit`) BEFORE the reveal is granted; the reveal then
      decrypts via the LIVE KMS. Anchoring the local record into the central T4.3
      chain is DEFERRED to when the control plane returns
      (`Samen.BreakGlass.Reconciliation`).
    * **KMS down** ⇒ the reveal FAILS CLOSED. Break-glass STILL calls the live KMS
      adapter to decrypt; there is NO degraded path that manufactures plaintext when
      the KMS is unreachable. `{:error, :unavailable}` from the vault propagates as a
      deny. (`deny-recoverable, by construction` — the doc.)

  ## The exact ordering (who/what/why BEFORE the reveal)

  `reveal/1`:

    1. **Validate who/what/why** — `:operator_id`, `:subject_id`, `:reason` are all
       required. A break-glass with no reason is refused `{:error, :reason_required}`
       BEFORE anything else (red path).
    2. **Suspension gate** — if the operator is suspended
       (`Samen.OperatorPlane.Suspension`), deny `{:error, :operator_suspended}`.
       Break-glass does NOT override a suspension (the suspension is the response to
       abuse; there is no emergency bypass of it).
    3. **Breadth budget** — record this reveal and check the per-operator distinct-
       subject budget (`Samen.BreakGlass.Budget`). If it trips, the operator is
       auto-suspended and THIS reveal denies `{:error, :budget_exceeded}`.
    4. **Local audit write (who/what/why)** — write the entry to the local hash
       chain, fsync'd. If this write FAILS, the whole break-glass fails closed
       `{:error, {:local_audit_failed, reason}}` — can't log it ⇒ can't see it
       (the local audit is the accountability the emergency path trades synchronous
       anchoring FOR, never accountability itself).
    5. **Live KMS decrypt** — call the single vault chokepoint (`Samen.Vault.reveal/3`),
       which unwraps the subject DEK via the LIVE KMS. KMS down ⇒ `{:error, :unavailable}`
       ⇒ deny.

  Success emits `[:samen, :break_glass, :reveal]` telemetry (unanchored count += 1
  until reconciliation).

  ## Single break-glass role convention

  Break-glass is a HIGH-privilege capability, gated on a single, named role:
  `:operator_break_glass` (see `authorized?/1`). By convention there is exactly ONE
  such role in an operator-plane RBAC (not a per-scope grab-bag) — the audit trail's
  "who could break glass" answer is a single, small, reviewable set. A non-break-
  glass operator (`:operator_support`, `:operator_readonly`, or a tenant actor)
  cannot break glass: `authorized?/1` returns false and `reveal/1` denies
  `{:error, :not_authorized}`. This is documented in the runbook.

  ## What is NOT bypassable

    * the KMS (clause (c)) — always a live call; KMS down = deny;
    * a suspension (clause (d)) — a suspended operator's break-glass denies;
    * the who/what/why (clause (a)) — no reason = deny, and the local audit write
      must succeed before the reveal.
  """

  alias Samen.BreakGlass.{LocalAudit, Budget}
  alias Samen.OperatorPlane.Suspension
  alias Samen.Masked

  @break_glass_role :operator_break_glass

  @typedoc "The break-glass request — the who/what/why plus the value to reveal."
  @type request :: %{
          required(:operator) => term(),
          required(:subject_id) => String.t(),
          required(:reason) => String.t(),
          required(:masked) => Masked.t(),
          required(:action) => atom(),
          required(:resource) => module(),
          optional(:org_id) => String.t(),
          optional(:repo) => module(),
          optional(:vault) => module(),
          optional(:local_audit_path) => String.t()
        }

  @doc "The single break-glass role name (convention: exactly one such role)."
  @spec break_glass_role() :: atom()
  def break_glass_role, do: @break_glass_role

  @doc """
  Is this actor authorized to break glass? True ONLY for an operator actor holding
  the single `:operator_break_glass` role. Everything else — other operator roles,
  tenant actors, the token-blind aggregate actor — is false (fail closed).
  """
  @spec authorized?(term()) :: boolean()
  def authorized?(%{kind: :operator, operator_role: @break_glass_role}), do: true
  def authorized?(_), do: false

  @doc """
  Perform a break-glass emergency reveal. See the module doc for the exact ordering.

  `req` (a map):
    * `:operator`  — the operator actor (must hold `:operator_break_glass`)
    * `:subject_id`— whose data (the vault subject / grant subject)
    * `:reason`    — REQUIRED who/what/why justification
    * `:masked`    — the `%Masked{}` value to reveal
    * `:action`    — the reveal action (declared reveal action on the resource)
    * `:resource`  — the Ash resource module
    * `:org_id`    — OPTIONAL chain partition (defaults to `"__global__"`)
    * `:repo`      — the Ecto repo (defaults to the suspension/reveal repo)
    * `:vault`     — OPTIONAL vault module (injectable for tests; default `Samen.Vault`)
    * `:local_audit_path` — OPTIONAL local audit file (injectable for tests)

  Returns:
    * `{:ok, %{plaintext: binary, local_entry: entry}}` — revealed; the who/what/why
      is durable locally and awaiting reconciliation;
    * `{:error, :reason_required}`  — no who/what/why (clause (a) red path);
    * `{:error, :not_authorized}`   — actor lacks the break-glass role;
    * `{:error, :operator_suspended}` — the operator is suspended (clause (d));
    * `{:error, :budget_exceeded}`  — this reveal tripped the breadth budget →
      operator auto-suspended (clause (d));
    * `{:error, {:local_audit_failed, reason}}` — the local audit could not be
      written; the reveal is refused (can't log it ⇒ can't see it);
    * `{:error, :unavailable}`      — KMS down; FAIL CLOSED (clause (c));
    * `{:error, :shredded | :not_found | term}` — from the vault.
  """
  @spec reveal(request()) :: {:ok, map()} | {:error, term}
  def reveal(req) when is_map(req) do
    with :ok <- require_reason(req),
         :ok <- require_authorized(req),
         :ok <- require_not_suspended(req),
         :ok <- require_within_budget(req),
         {:ok, entry} <- write_local_audit(req),
         {:ok, plaintext} <- live_kms_reveal(req) do
      :telemetry.execute(
        [:samen, :break_glass, :reveal],
        %{count: 1},
        %{
          operator_id: operator_id(req),
          subject_id: req.subject_id,
          org_id: org_id(req),
          seq: entry.seq
        }
      )

      {:ok, %{plaintext: plaintext, local_entry: entry}}
    end
  end

  # (a) who/what/why — reason is required, non-empty.
  defp require_reason(req) do
    case Map.get(req, :reason) do
      r when is_binary(r) and byte_size(r) > 0 -> :ok
      _ -> {:error, :reason_required}
    end
  end

  # role gate — the single break-glass role.
  defp require_authorized(req) do
    if authorized?(Map.get(req, :operator)), do: :ok, else: {:error, :not_authorized}
  end

  # (d) a suspended operator cannot break glass (no emergency override).
  defp require_not_suspended(req) do
    repo = repo(req)

    if Suspension.suspended?(operator_id(req), repo: repo) do
      {:error, :operator_suspended}
    else
      :ok
    end
  end

  # (d) breadth budget — record this reveal and check. Tripping it auto-suspends
  # the operator and denies THIS reveal.
  defp require_within_budget(req) do
    case Budget.record_and_check(%{
           operator_id: operator_id(req),
           subject_id: req.subject_id,
           break_glass: true,
           org_id: org_id(req),
           repo: repo(req)
         }) do
      {:ok, _count} -> :ok
      {:suspended, _count} -> {:error, :budget_exceeded}
    end
  end

  # (a) local audit BEFORE the reveal. Failure fails the whole thing closed.
  defp write_local_audit(req) do
    attrs = %{
      org_id: org_id(req),
      subject_id: req.subject_id,
      actor_id: operator_id(req),
      reason: req.reason,
      resource: Map.get(req, :resource),
      action: Map.get(req, :action)
    }

    opts =
      case Map.get(req, :local_audit_path) do
        nil -> []
        path -> [path: path]
      end

    case LocalAudit.append(attrs, opts) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, {:local_audit_failed, reason}}
    end
  end

  # (c) the LIVE KMS decrypt — the same single vault chokepoint the routine path
  # uses. KMS unreachable ⇒ {:error, :unavailable} ⇒ deny. There is NO bypass.
  defp live_kms_reveal(req) do
    vault = Map.get(req, :vault, Samen.Vault)
    repo = repo(req)
    vault.reveal(req.masked, repo, subject_id: req.subject_id)
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp repo(req) do
    Map.get(req, :repo) || Samen.OperatorPlane.Suspension.repo()
  end

  defp org_id(req), do: Map.get(req, :org_id) || Samen.AuditChain.global_org()

  defp operator_id(req) do
    case Map.get(req, :operator) do
      %{id: id} when is_binary(id) -> id
      id when is_binary(id) -> id
      _ -> nil
    end
  end
end
