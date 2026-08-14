defmodule Samen.Approvals do
  @moduledoc """
  E3 — the generalized approve/reject engine (ADR-040 §4; spec §E3). Two-party
  decision-making as a substrate primitive, carrying the reveal-grade enforcement stack
  (policy + DB CHECK + governance audit). Reveal grants become its first client in T35
  (§4.7) with zero observable change — this module is designed so that migration keeps
  every reveal test unmodified.

  ## Host-wired seam (the `Notifications.Engine` convention)

  The engine operates on a host-configured `Approval` resource + repo:

      config :samen_core, Samen.Approvals,
        approval_resource: MyApp.Primitives.Approval,
        repo: MyApp.Repo

  Unwired ⇒ fail-closed `{:error, :no_approvals_module}` — never a silent single-party
  decision. `kind => {plane, handler}` registration lives in `Samen.Approvals.Registry`.

  ## The four binding facts (ADR-040 §4)

    1. **Requester ≠ approver, two layers** (§4.2): `approve/3`/`reject/3` refuse
       `decided_by == requested_by` with `{:error, :self_approval}` + a refusal audit
       (the approval stays `pending`), AND the `<abbrev>_distinct_party` DB CHECK
       (`decided_by IS NULL OR decided_by <> requested_by`) rejects any insert/update that
       slips past the policy — the `rvg_distinct_party` twin. NULL-org operator/reveal
       kinds share the same CHECK (the check keys on the parties, not the org).
    2. **Exactly-once by state machine** (§4.3): the decision transition is
       `pending → approved | rejected`, machine-guarded — a second decide on a non-pending
       row is refused (`{:error, :not_pending}`; the AshStateMachine `NoMatchingTransition`
       is the underlying guard). The gated action executes AT MOST once.
    3. **Decision + handler + audit in ONE transaction** (§4.3): the transition, the
       registered handler's `on_approve/2`, and the governance audit ride one repo
       transaction. A handler error rolls the whole thing back — the approval stays
       `pending` (this preserves the reveal same-tx guarantee for T35).
    4. **No persisted inputs** (§4.4, INV-1): an approval row is
       `{org_id, kind, subject_ref, parties, reason, state}` — never the action's inputs.
       The handler re-derives the work from governed domain state via `subject_ref`. No
       plaintext PII / `vt_*` token ever lands in an approval row; `reason` is
       PiiReasonScan-gated at write and never enters audit-chain detail.
  """

  alias Samen.Approvals.Registry

  require Ash.Query

  @typep wiring :: {module(), module()}

  # ==========================================================================
  # Public API — the binding signatures (ADR-040 §4.4).
  # ==========================================================================

  @doc """
  Open (or return the existing pending) approval. Idempotent per `{org_id, kind,
  subject_ref}` while pending (the partial unique index). Refuses an unregistered `kind`
  and a PII-shaped `reason` at write. Writes an `approval_requested` audit.

  `attrs`: `%{org_id: id | nil, kind: String.t(), subject_ref: String.t(),
  requested_by: id, reason: String.t() | nil, deadline_at: DateTime.t() | nil}`.
  """
  @spec request(map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def request(attrs, opts \\ []) do
    with {:ok, {res, repo}} <- wiring(opts),
         {:ok, kind} <- fetch_kind(attrs),
         {:ok, _} <- Registry.resolve(kind, opts),
         :ok <- scan_reason(fetch(attrs, :reason)) do
      case existing_pending(res, attrs, opts) do
        {:ok, approval} ->
          {:ok, approval}

        :none ->
          create_approval(res, repo, attrs, kind, opts)
      end
    end
  end

  defp fetch_kind(attrs) do
    case fetch(attrs, :kind) do
      kind when is_binary(kind) -> {:ok, kind}
      _ -> {:error, :missing_kind}
    end
  end

  @doc """
  Approve `approval_id` as the DISTINCT party `decided_by`. Runs the registered handler's
  `on_approve/2` inside the decision transaction. Returns `{:ok, approval, meta}` or
  `{:error, :self_approval | :not_pending | :no_approvals_module | term()}`.
  """
  @spec approve(term(), term(), keyword()) ::
          {:ok, struct(), map()} | {:error, term()}
  def approve(approval_id, decided_by, opts \\ []),
    do: decide(approval_id, decided_by, :approve, opts)

  @doc """
  Reject `approval_id` as the DISTINCT party `decided_by`. Symmetric with `approve/3`;
  runs the handler's optional `on_reject/2` (default no-op). The gated action NEVER runs.
  Returns `{:ok, approval}` or `{:error, term()}`.
  """
  @spec reject(term(), term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def reject(approval_id, decided_by, opts \\ []) do
    case decide(approval_id, decided_by, :reject, opts) do
      {:ok, approval, _meta} -> {:ok, approval}
      {:error, _} = err -> err
    end
  end

  @doc """
  Cancel `approval_id` (the requester withdraws). `pending → cancelled`, audited. No
  handler runs. Returns `{:ok, approval}` or `{:error, term()}`.
  """
  @spec cancel(term(), term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def cancel(approval_id, actor, opts \\ []) do
    with {:ok, {res, repo}} <- wiring(opts),
         {:ok, approval} <- fetch_approval(res, approval_id, opts) do
      cond do
        approval.state != :pending ->
          {:error, :not_pending}

        true ->
          repo.transaction(fn ->
            # A cancel is the requester WITHDRAWING, not a two-party decision — it never
            # sets `decided_by` (leaving it NULL keeps the distinct-party CHECK satisfied
            # even when the canceller is the requester). The canceller is recorded in audit.
            case transition(approval, :cancel, %{}, opts) do
              {:ok, cancelled} ->
                audit(repo, cancelled, "approval_cancelled", actor)
                cancelled

              {:error, reason} ->
                repo.rollback(reason)
            end
          end)
      end
    end
  end

  @doc """
  Look up an approval by id through the engine's wiring (bypasses authorization — a
  kernel read for handlers/tests). Returns `{:ok, approval}` or `{:error, :not_found}`.
  """
  @spec get(term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def get(approval_id, opts \\ []) do
    with {:ok, {res, _repo}} <- wiring(opts) do
      fetch_approval(res, approval_id, opts)
    end
  end

  @doc """
  List the PENDING approvals of `kind` for `org_id` — the ORG-SCOPED read a tenant
  approver surface consults (PP-13). Reuses the engine's own `existing_pending`/`org_filter`
  shape as a governed list read: a non-NULL `org_id` returns ONLY that org's pending rows
  (`org_id == ^org_id`), so a tenant approver can never see — nor act on — another org's
  pending decisions (the cross-org read the OrgScope policy also forbids on the tenant plane).

  Bypasses authorization like the other kernel engine reads (`get/2`, `existing_pending/3`) —
  a trusted kernel API; the org isolation here is the `org_filter/2` conjunct itself, NOT the
  resource policy (which the engine's own reads run `authorize?: false` past). Newest-last
  (oldest pending first) so the approver works the queue in arrival order.

  Returns `{:ok, [approval]}` or `{:error, :no_approvals_module}` (unwired host).
  """
  @spec list_pending(term(), String.t(), keyword()) :: {:ok, [struct()]} | {:error, term()}
  def list_pending(org_id, kind, opts \\ []) when is_binary(kind) do
    with {:ok, {res, _repo}} <- wiring(opts) do
      query =
        res
        |> Ash.Query.filter(state == :pending and kind == ^kind)
        |> org_filter(org_id)
        |> Ash.Query.sort(requested_at: :asc)

      # authz-scope: org-pinned one clause down via org_filter/2 (binary org => org_id == ^org_id;
      # nil => is_nil(org_id), the deliberate GLOBAL lane) — a cross-clause pin the static check cannot see
      case Ash.read(query, authorize?: false) do
        {:ok, approvals} -> {:ok, approvals}
        {:error, _} = err -> err
      end
    end
  end

  # ==========================================================================
  # Decision core (approve/reject) — one transaction, handler in-tx, then audit.
  # ==========================================================================

  defp decide(approval_id, decided_by_raw, decision, opts) do
    decided_by = to_actor_id(decided_by_raw)

    with {:ok, {res, repo}} <- wiring(opts),
         {:ok, approval} <- fetch_approval(res, approval_id, opts),
         {:ok, {_plane, handler}} <- Registry.resolve(approval.kind, opts) do
      cond do
        # POLICY LAYER — mandatory approver (T34-F1 closure). An approval is a TWO-party
        # decision: a nil/empty approver identity is a single-party decision and is refused
        # fail-closed BEFORE the transition, so a NULL approver never reaches the DB. This is
        # the app-layer twin of the DB CHECK's `apv_decided_by IS NOT NULL on a decided row`
        # (below) — distinct-party is meaningless without a party. (The reveal precedent
        # excludes NULL at READ via `granted_by != requestor_id`; this excludes it at WRITE.)
        blank_actor?(decided_by) ->
          {:error, :no_approver}

        approval.state != :pending ->
          {:error, :not_pending}

        # POLICY LAYER (§4.2 layer 1): refuse self-decision before touching the DB, write
        # a refusal audit, leave the approval pending. The DB CHECK (layer 2) is the twin.
        decided_by == to_actor_id(approval.requested_by) ->
          audit(repo, approval, "approval_self_decide_refused", decided_by)
          {:error, :self_approval}

        true ->
          run_decision(repo, res, approval, decided_by, decision, handler, opts)
      end
    end
  end

  defp blank_actor?(nil), do: true
  defp blank_actor?(""), do: true
  defp blank_actor?(id) when is_binary(id), do: String.trim(id) == ""
  defp blank_actor?(_), do: false

  # The decision transaction (§4.3): transition (machine-guarded) → handler in-tx → audit.
  defp run_decision(repo, _res, approval, decided_by, decision, handler, opts) do
    result =
      repo.transaction(fn ->
        with {:ok, decided} <- transition(approval, decision, %{decided_by: decided_by}, opts),
             {:ok, meta} <- run_handler(handler, decided, decided_by, decision, repo, opts) do
          audit(repo, decided, event_for(decision), decided_by)
          {decided, meta}
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {decided, meta}} -> {:ok, decided, meta}
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs the registered handler INSIDE the decision transaction. on_approve is required;
  # on_reject is optional (default no-op). A handler error aborts the whole decision.
  defp run_handler(handler, approval, decided_by, :approve, repo, opts) do
    ctx = %{approval: approval, actor: decided_by, repo: repo, opts: opts}

    case handler.on_approve(approval, ctx) do
      {:ok, meta} when is_map(meta) -> {:ok, meta}
      {:error, _} = err -> err
      other -> {:error, {:bad_handler_return, other}}
    end
  end

  defp run_handler(handler, approval, decided_by, :reject, repo, opts) do
    ctx = %{approval: approval, actor: decided_by, repo: repo, opts: opts}

    if exports?(handler, :on_reject, 2) do
      case handler.on_reject(approval, ctx) do
        :ok -> {:ok, %{}}
        {:error, _} = err -> err
        other -> {:error, {:bad_handler_return, other}}
      end
    else
      {:ok, %{}}
    end
  end

  # T143: resolve an OPTIONAL handler callback fail-closed against lazy module loading.
  # `function_exported?/3` does NOT auto-load a module and returns `false` for one not yet
  # loaded — so a handler's optional `on_reject/2` could be SILENTLY SKIPPED (a rejected
  # draft left un-discarded) in a non-embedded/interactive runtime where the reject is
  # processed before any path loaded the handler. `Code.ensure_loaded?/1` forces the load
  # first, so detection reflects what the module ACTUALLY defines — not load order. (This
  # replaces the T70 `Code.ensure_loaded/1` band-aid every future on_reject client would
  # otherwise have to remember: the ENGINE now owns the guarantee.)
  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  # ==========================================================================
  # Ash-action plumbing (writes bypass authorization — a trusted kernel API, the
  # Grants precedent; distinct-party is enforced in-engine + by the DB CHECK, and the
  # resource's own OrgScope/RoleAtLeast policies govern tenant-surface READS/decides).
  # ==========================================================================

  defp create_approval(res, repo, attrs, kind, opts) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    create_attrs = %{
      org_id: fetch(attrs, :org_id),
      kind: kind,
      subject_ref: fetch(attrs, :subject_ref),
      requested_by: to_actor_id(fetch(attrs, :requested_by)),
      reason: fetch(attrs, :reason),
      deadline_at: fetch(attrs, :deadline_at),
      requested_at: now
    }

    result =
      repo.transaction(fn ->
        case res
             |> Ash.Changeset.for_create(:open, create_attrs, authorize?: false)
             |> Ash.create() do
          {:ok, approval} ->
            audit(repo, approval, "approval_requested", create_attrs.requested_by)
            approval

          # Lost an idempotency race — the partial unique index rejected a duplicate
          # pending row. Return the existing pending approval (idempotent request).
          {:error, _} = err ->
            repo.rollback(err)
        end
      end)

    case result do
      {:ok, approval} ->
        {:ok, approval}

      {:error, _} ->
        case existing_pending(res, attrs, opts) do
          {:ok, approval} -> {:ok, approval}
          :none -> {:error, :request_failed}
        end
    end
  end

  # The machine-guarded transition. Ash nests inside the ambient decision transaction via
  # a savepoint (repo.transaction wraps it), so a handler error / repo.rollback aborts the
  # transition too; a transition off a non-pending row errors (exactly-once — the
  # AshStateMachine NoMatchingTransition underlies :not_pending).
  defp transition(approval, action, attrs, _opts) do
    approval
    |> Ash.Changeset.for_update(action, attrs, authorize?: false)
    |> Ash.update()
  end

  defp existing_pending(res, attrs, _opts) do
    kind = fetch(attrs, :kind)
    subject_ref = fetch(attrs, :subject_ref)
    org_id = fetch(attrs, :org_id)

    query =
      res
      |> Ash.Query.filter(state == :pending and kind == ^kind and subject_ref == ^subject_ref)
      |> org_filter(org_id)
      |> Ash.Query.limit(1)

    # authz-scope: org-pinned one clause down via org_filter/2 (binary org => org_id == ^org_id;
    # nil => is_nil(org_id), the deliberate GLOBAL lane) — a cross-clause pin the static check cannot see
    case Ash.read(query, authorize?: false) do
      {:ok, [approval]} -> {:ok, approval}
      _ -> :none
    end
  end

  defp org_filter(query, nil), do: Ash.Query.filter(query, is_nil(org_id))
  defp org_filter(query, org_id), do: Ash.Query.filter(query, org_id == ^org_id)

  defp fetch_approval(res, approval_id, _opts) do
    case Ash.get(res, approval_id, authorize?: false) do
      {:ok, approval} -> {:ok, approval}
      {:error, _} -> {:error, :not_found}
    end
  end

  # ==========================================================================
  # Audit — governance chain, token/id-only detail (§4.3). `reason` NEVER enters detail.
  # ==========================================================================

  defp audit(repo, approval, event_type, actor_id) do
    Samen.AuditChain.Writer.write(repo, %{
      org_id: approval.org_id || Samen.AuditChain.global_org(),
      event_type: event_type,
      # subject_ref is an object-ref string ("samen:scope.resource:<id>") — token-safe.
      subject_id: approval.subject_ref,
      actor_id: to_actor_id(actor_id),
      correlation_id: to_string(approval.id),
      detail: "event=#{event_type} kind=#{approval.kind}",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  end

  # ==========================================================================
  # Reason scan + wiring/seam resolution.
  # ==========================================================================

  defp scan_reason(nil), do: :ok

  defp scan_reason(reason) when is_binary(reason) do
    Samen.PiiReasonScan.check(reason, "approval reason")
  end

  @spec wiring(keyword()) :: {:ok, wiring()} | {:error, :no_approvals_module}
  defp wiring(opts) do
    res = opt(opts, :approval_resource)
    repo = opt(opts, :repo) || res_repo(res)

    cond do
      is_nil(res) -> {:error, :no_approvals_module}
      is_nil(repo) -> {:error, :no_approvals_module}
      true -> {:ok, {res, repo}}
    end
  end

  defp res_repo(nil), do: nil

  defp res_repo(res) do
    AshPostgres.DataLayer.Info.repo(res)
  rescue
    _ -> nil
  end

  defp event_for(:approve), do: "approval_approved"
  defp event_for(:reject), do: "approval_rejected"

  defp to_actor_id(nil), do: nil
  defp to_actor_id(id) when is_binary(id), do: id
  defp to_actor_id(%{id: id}) when is_binary(id), do: id
  defp to_actor_id(other), do: to_string(other)

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp opt(opts, key) do
    Keyword.get(opts, key) || Keyword.get(config(), key)
  end

  defp config, do: Application.get_env(:samen_core, __MODULE__, [])
end
