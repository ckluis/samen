defmodule Samen.Reveal.Grants do
  @moduledoc """
  The reveal-grant model (T1.6; doc §control "'Time-boxed' is a built mechanism,
  not an adjective"; D6). This is what the `Samen.Reveal.Grant` seam consults for
  operator-class actors.

  ## Lifecycle

    1. `request/1` — a requestor files a `RevealRequest` (subject, reason,
       scope). Grants nothing on its own; writes a `requested` audit row.
    2. `approve/2` — a DISTINCT party approves the request. This writes a
       `RevealGrant` with a bounded `expires_at` AND enqueues the
       `AutoRevokeWorker` (scheduled at `expires_at`) **in the same transaction**
       (clause (d)). Self-approval is refused at the POLICY layer here AND at the
       DB layer by the `rvg_distinct_party` CHECK (clause (b)).
    3. reveal reads consult `active?/2` — which DENIES the moment
       `now() > expires_at`, even if the row is never cleaned up (clause (c):
       deny on read, not on cleanup), and denies if `revoked_at` is set.
    4. `AutoRevokeWorker` flips `revoked_at` at `expires_at` (reconciliation, not
       the safety mechanism).

  ## The `reason` free-text is a NON-shreddable plaintext channel (F4.3)

  The requestor-authored `reason` on a `RevealRequest` is **plaintext metadata**: it is
  stored on `rvr_reveal_request` and copied into the `requested` audit `detail`. A subject
  crypto-shred does NOT erase it (a DEK destruction cannot reach a plaintext column;
  the audit chain deliberately preserves the detail token — ADR-002 §2.5). So the
  "who it was about becomes unrecoverable" guarantee holds for the vaulted PII but NOT
  for whatever a requestor freely typed here. `request/1` runs
  `Samen.PiiReasonScan.check/2` (email/SSN/phone value-shape scan, fail-closed REJECT) at
  the write boundary and refuses a PII-shaped reason with `{:error, {:pii_shaped_reason,
  shape}}` before any row lands. Best-effort belt, not a taint proof; the load-bearing
  control is the human convention "reasons name the ticket, not the person."

  ## No renew-in-place (clause (e))

  There is NO function here that mutates a grant's `expires_at`. `revoke/2` only
  sets `revoked_at`. Re-access requires a fresh `request/1` + `approve/2`, which
  writes a NEW grant. `attempt_extend/2` exists ONLY so the red-path test can
  prove that extending a grant's window fails.

  ## Configuration

      config :samen_core, :reveal_grant_repo, MyApp.Repo
      # Default reveal window (minutes). Bounded default per clause (a).
      config :samen_core, :reveal_grant_default_window_minutes, 15

  ## Operator-class actors

  `Samen.Reveal.Grants` implements `Samen.Reveal.Grant`. Wire it via
  `config :samen_core, :reveal_grant, Samen.Reveal.Grants`. `granted?/1`
  interprets the context actor as operator-class: it looks for an ACTIVE,
  unexpired, distinct-party grant for `(actor, subject_id)` and returns `true`
  only then. Any missing/expired/revoked/self-approved grant returns `false` —
  fail closed.
  """

  alias Samen.Reveal.{RevealRequest, RevealGrant, RevealAudit, AutoRevokeWorker}
  alias Samen.Reveal.Context

  import Ecto.Query, only: [from: 2]

  @behaviour Samen.Reveal.Grant

  @default_window_minutes 15

  # ==========================================================================
  # Configuration helpers
  # ==========================================================================

  @doc "The Ecto repo backing the grant model. Configure via `:reveal_grant_repo`."
  @spec repo() :: module()
  def repo do
    Application.get_env(:samen_core, :reveal_grant_repo) ||
      raise """
      Samen.Reveal.Grants needs a repo. Configure it:

          config :samen_core, :reveal_grant_repo, MyApp.Repo
      """
  end

  @doc """
  The default reveal window in minutes (bounded default per clause (a)).
  Configure via `:reveal_grant_default_window_minutes`; defaults to 15.
  """
  @spec default_window_minutes() :: pos_integer()
  def default_window_minutes do
    Application.get_env(:samen_core, :reveal_grant_default_window_minutes, @default_window_minutes)
  end

  # ==========================================================================
  # 1. Request
  # ==========================================================================

  @doc """
  File a reveal request. Grants nothing on its own. Writes a `requested` audit
  row. Returns `{:ok, %RevealRequest{}}`.

  Required: `:subject_id`, `:requestor_id`, `:reason`. Optional: `:resource`,
  `:action`, `:repo` (defaults to the configured repo).
  """
  @spec request(map()) :: {:ok, RevealRequest.t()} | {:error, term}
  def request(attrs) do
    r = Map.get(attrs, :repo, repo())
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with :ok <- Samen.PiiReasonScan.check(attrs[:reason], "reveal-request reason") do
      do_request(r, attrs, now)
    end
  end

  # F4.3: the reveal-request `reason` is a NON-shreddable plaintext channel (ADR-002
  # §2.5) — it lands in `rvr_reveal_request` and flows into the `requested` audit
  # `detail`. Reject a reason that is *itself* an email/SSN/phone value shape BEFORE any
  # write (fail-closed default), so subject PII never enters a channel a later
  # crypto-shred cannot reach.
  defp do_request(r, attrs, now) do
    changeset =
      %RevealRequest{}
      |> Ecto.Changeset.cast(
        %{
          subject_id: fetch!(attrs, :subject_id),
          requestor_id: fetch!(attrs, :requestor_id),
          reason: fetch!(attrs, :reason),
          resource: attrs[:resource] && to_string(attrs[:resource]),
          action: attrs[:action] && to_string(attrs[:action]),
          status: "pending",
          inserted_at: now,
          updated_at: now
        },
        [:subject_id, :requestor_id, :reason, :resource, :action, :status, :inserted_at, :updated_at]
      )
      |> Ecto.Changeset.validate_required([:subject_id, :requestor_id, :reason])

    with {:ok, req} <- r.insert(changeset) do
      write_audit(r, %{
        event: "requested",
        subject_id: req.subject_id,
        actor_id: req.requestor_id,
        request_id: req.id,
        detail: req.reason,
        # PP-11 (T150): ride the SUBJECT'S TENANT org chain when the caller supplies
        # `org_id`, so the "who requested to unmask what, when, why" event is visible on
        # THAT tenant's `Settings.SecurityLive` ledger. Absent an org_id it falls to the
        # reserved `__global__` operator chain (`write_audit/2` / ADR-002 §2.1) — the
        # pre-PP-11 behavior for callers that have not threaded the target org.
        org_id: attrs[:org_id]
      })

      # T35 §4.7: additionally open a `pii_reveal` Approval through the T34 engine —
      # dual truth, per the ADR. The `RevealRequest` row (just written above) STAYS the
      # domain intent record; this is a best-effort parallel governance record so an
      # approval surface can see the pending decision even before `approve/2` is called.
      # Never blocks/fails the reveal request itself: an unwired host, an unregistered
      # kind, or any other engine hiccup here must not regress `request/1`'s pre-T35
      # contract (RevealRequest write + `requested` audit, unconditionally).
      open_engine_approval(req, attrs[:org_id])

      {:ok, req}
    end
  end

  defp open_engine_approval(%RevealRequest{} = req, org_id) do
    Samen.Approvals.request(%{
      # PP-11: carry the target tenant org onto the parallel `pii_reveal` approval so its
      # governance-audit rows (approval_requested/approved) also ride the TENANT chain, not
      # `__global__`. Nil preserves the pre-PP-11 org-less operator-chain behavior.
      org_id: org_id,
      kind: "pii_reveal",
      subject_ref: Samen.Reveal.ApprovalHandler.subject_ref(req),
      requested_by: req.requestor_id
    })

    :ok
  rescue
    _ -> :ok
  end

  # ==========================================================================
  # 2. Approve — DISTINCT-party, same-tx auto-revoke enqueue
  # ==========================================================================

  @doc """
  Approve a `RevealRequest` as a DISTINCT party (`granted_by`). Writes a
  `RevealGrant` AND enqueues the `AutoRevokeWorker` (scheduled at `expires_at`)
  in the SAME transaction (clause (d)).

  Distinct-party is enforced at BOTH layers (clause (b)):
    * POLICY: this function refuses `{:error, :self_approval}` before touching
      the DB when `granted_by == request.requestor_id`.
    * DB: the `rvg_distinct_party` CHECK constraint would reject the insert
      even if this policy check were bypassed.

  Options:
    * `:window_minutes` — override the bounded default window.
    * `:repo` — override the configured repo.

  Returns `{:ok, %RevealGrant{}}` or `{:error, reason}`. On error, NOTHING is
  written and no job is enqueued (the whole multi rolls back).
  """
  @spec approve(RevealRequest.t() | binary(), map()) ::
          {:ok, RevealGrant.t()} | {:error, term}
  def approve(request_or_id, opts \\ %{})

  def approve(%RevealRequest{} = req, opts) do
    granted_by = fetch!(opts, :granted_by)
    r = Map.get(opts, :repo, repo())

    # POLICY-LAYER distinct-party check (clause (b), layer 1). The DB CHECK is
    # layer 2 and would also reject a self-approval insert.
    if granted_by == req.requestor_id do
      write_audit(r, %{
        event: "denied",
        subject_id: req.subject_id,
        actor_id: granted_by,
        request_id: req.id,
        detail: "self-approval refused (policy layer)"
      })

      {:error, :self_approval}
    else
      route_through_engine(req, granted_by, opts, r)
    end
  end

  def approve(request_id, opts) when is_binary(request_id) do
    r = Map.get(opts, :repo, repo())

    case r.get(RevealRequest, request_id) do
      nil -> {:error, :request_not_found}
      %RevealRequest{} = req -> approve(req, opts)
    end
  end

  # ==========================================================================
  # T35 §4.7 — route the happy path through the T34 approvals engine.
  # ==========================================================================

  # Opens (fetches-or-creates, idempotent) the `pii_reveal` Approval for this request and
  # decides it through `Samen.Approvals.approve/3`. The registered handler
  # (`Samen.Reveal.ApprovalHandler`) runs `do_approve/4` (below) INSIDE the engine's
  # decision transaction, so the T34 guarantees (exactly-once by state machine,
  # distinct-party incl. the T34-F1 null-approver refusal, same-tx handler+audit) now
  # apply to reveal. `window_minutes` is NOT persisted on the approval row (§4.4,
  # no-persisted-inputs) — it rides the synchronous `opts` keyword list into `ctx.opts`,
  # the same call-time value the pre-T35 inline path always used.
  #
  # An UNWIRED host (`{:error, :no_approvals_module}`, e.g. no `pii_reveal` registration
  # yet — the per-host sweep residual, ADR-040 §4.7 item 4) falls back to the ORIGINAL
  # inline `do_approve/4` call, preserving exact pre-migration behavior rather than
  # regressing a host that has not adopted the engine. Reveal's own distinct-party
  # enforcement (policy above + the `rvg_distinct_party` DB CHECK) still fully applies on
  # that fallback path — "unwired" never means "single-party grant slips through", it
  # only means the T34-specific guarantees (exactly-once machine, T34-F1) are not yet
  # layered on top for that host.
  defp route_through_engine(req, granted_by, opts, r) do
    approval_attrs = %{
      # PP-11: the approval carries the target tenant org (idempotent with the request-time
      # open above), so the engine's approval_approved chain row rides the TENANT chain.
      org_id: Map.get(opts, :org_id),
      kind: "pii_reveal",
      subject_ref: Samen.Reveal.ApprovalHandler.subject_ref(req),
      requested_by: req.requestor_id
    }

    engine_opts = [
      window_minutes: Map.get(opts, :window_minutes, default_window_minutes()),
      # Rides into `ctx.opts` → `do_approve/4` (via the ApprovalHandler) so the granted-side
      # audit is tenant-attributed on BOTH the engine path and the no_approvals_module
      # fallback below (which passes `opts` straight through).
      org_id: Map.get(opts, :org_id)
    ]

    with {:ok, approval} <- Samen.Approvals.request(approval_attrs),
         {:ok, _decided, meta} <- Samen.Approvals.approve(approval.id, granted_by, engine_opts) do
      {:ok, r.get!(RevealGrant, meta.grant_id)}
    else
      {:error, :no_approvals_module} ->
        do_approve(req, granted_by, opts, r)

      {:error, _reason} = err ->
        err
    end
  end

  @doc false
  # Public (not private) so `Samen.Reveal.ApprovalHandler.on_approve/2` — the registered
  # T34 engine handler for kind "pii_reveal" — can invoke this EXACT Multi body inside the
  # engine's decision transaction (§4.7 item 2). Behavior is UNCHANGED from the pre-T35
  # inline call: same grant insert + `granted` audit + same-tx auto-revoke enqueue.
  @spec do_approve(RevealRequest.t(), term(), map(), module()) ::
          {:ok, RevealGrant.t()} | {:error, term()}
  def do_approve(req, granted_by, opts, r) do
    window = Map.get(opts, :window_minutes, default_window_minutes())
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, window * 60, :second)

    grant_id = Ecto.UUID.generate()

    grant_attrs = %{
      id: grant_id,
      request_id: req.id,
      subject_id: req.subject_id,
      requestor_id: req.requestor_id,
      granted_by: granted_by,
      reason: req.reason,
      resource: req.resource,
      action: req.action,
      expires_at: expires_at,
      inserted_at: now,
      updated_at: now
    }

    # SAME-TX ENQUEUE (clause (d)): the grant INSERT, the audit INSERT, and the
    # Oban job enqueue all ride ONE Ecto.Multi / ONE transaction. If any step
    # fails (e.g. the DB CHECK rejects a self-approval that slipped past the
    # policy check), the whole thing rolls back — no grant, no audit, NO job.
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:grant, grant_changeset(grant_attrs))
      |> Ecto.Multi.insert(:audit, audit_changeset(%{
        event: "granted",
        subject_id: req.subject_id,
        actor_id: granted_by,
        request_id: req.id,
        grant_id: grant_id,
        detail: "expires_at=#{DateTime.to_iso8601(expires_at)}"
      }))
      |> Oban.insert(:auto_revoke, AutoRevokeWorker.new(%{grant_id: grant_id},
        scheduled_at: expires_at
      ))

    case r.transaction(multi) do
      {:ok, %{grant: grant}} -> {:ok, grant}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # ==========================================================================
  # 3. Deny-on-read policy (clause (c))
  # ==========================================================================

  @doc """
  Is there an ACTIVE, unexpired, distinct-party grant that authorizes THIS actor
  (as the **requestor**) to reveal `subject_id`?

  ## Who holds the reveal capability (Gate-0 vault-stack fix, P1 authz)

  The capability binds to the **REQUESTOR**, gated on a **distinct approver** —
  NOT to the approver. `active?/2` returns `true` only when there is a grant whose
  `requestor_id == actor` AND whose `granted_by != requestor_id` (a distinct party
  approved it). The approver enables; the requestor reveals.

  This closes the self-serve-via-throwaway-requestor collusion the earlier
  approver-is-revealer model left open: an operator could file a throwaway
  `RevealRequest` (as a burner `requestor_id`) and then approve it themselves,
  ending up holding the reveal capability as the approver. Under the requestor-
  bound model, the operator would have to BE the requestor to reveal — and then a
  DISTINCT second party must approve, so a single actor can never both request and
  authorize their own reveal.

  This is the deny-on-read policy (clause (c)): it DENIES the moment
  `now() > expires_at`, computed against the row's `expires_at`, with NO dependence
  on the auto-revoke job having run. A revoked grant (revoked_at set) also denies.

  Returns `true` only for a live grant authorizing `actor` as the distinct-party-
  approved requestor. Everything else → `false` (fail closed).
  """
  @spec active?(term(), String.t(), keyword()) :: boolean()
  def active?(actor, subject_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    requestor_id = actor_id(actor)

    query =
      from(g in RevealGrant,
        where:
          g.subject_id == ^subject_id and
            # Capability binds to the REQUESTOR, not the approver (P1 authz fix).
            g.requestor_id == ^requestor_id and
            # DISTINCT-PARTY invariant re-checked on read: never honor a grant
            # whose approver equals its requestor (defence in depth over the DB
            # CHECK — a row can never have this, but we refuse it on read too, so
            # a self-approved grant can never authorize a reveal).
            g.granted_by != g.requestor_id and
            is_nil(g.revoked_at) and
            g.expires_at > ^now,
        select: g.id,
        limit: 1
      )

    r.exists?(query)
  end

  @doc """
  List the ACTIVE reveal windows this actor currently holds AS THE REQUESTOR — the
  legibility data for the R-P6 reveal-window UI (who approved, when it expires).

  This is a READ-ONLY accountability projection: it applies the SAME gate as
  `active?/3` (requestor-bound, distinct-party, unrevoked, `expires_at > now`) and returns
  the grant facts `%{subject_id, granted_by, expires_at}` instead of a boolean. It does
  NOT change enforcement — `active?/3` remains the authorization chokepoint; this only
  surfaces the already-recorded grant so a human can SEE that a privileged window is open,
  by whom, and until when.

  Note the honest scope: a reveal grant is SUBJECT-WIDE (keyed on `subject_id` +
  `requestor_id`, no field filter), so an open window authorizes resolving the whole
  subject record, not a single field — the UI copy must say so.
  """
  @spec active_windows(term(), keyword()) :: [
          %{subject_id: String.t(), granted_by: String.t(), expires_at: DateTime.t()}
        ]
  def active_windows(actor, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    requestor_id = actor_id(actor)

    r.all(
      from(g in RevealGrant,
        where:
          g.requestor_id == ^requestor_id and
            g.granted_by != g.requestor_id and
            is_nil(g.revoked_at) and
            g.expires_at > ^now,
        select: %{
          subject_id: g.subject_id,
          granted_by: g.granted_by,
          expires_at: g.expires_at
        }
      )
    )
  end

  # ==========================================================================
  # 4. Revoke (manual) — sets revoked_at only, never expires_at
  # ==========================================================================

  @doc """
  Manually revoke a grant now. Sets `revoked_at` (NOT `expires_at` — clause (e)).
  Writes a `revoked` audit row. Idempotent.
  """
  @spec revoke(binary(), map()) :: {:ok, RevealGrant.t()} | {:error, term}
  def revoke(grant_id, opts \\ %{}) do
    r = Map.get(opts, :repo, repo())
    actor = Map.get(opts, :actor_id, "system:manual_revoke")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case r.get(RevealGrant, grant_id) do
      nil ->
        {:error, :not_found}

      %RevealGrant{revoked_at: nil} = grant ->
        {:ok, revoked} =
          grant
          |> Ecto.Changeset.change(revoked_at: now, updated_at: now)
          |> r.update()

        write_audit(r, %{
          event: "revoked",
          subject_id: grant.subject_id,
          actor_id: actor,
          request_id: grant.request_id,
          grant_id: grant.id,
          detail: "manual revoke"
        })

        {:ok, revoked}

      %RevealGrant{} = grant ->
        {:ok, grant}
    end
  end

  # ==========================================================================
  # 5. No renew-in-place (clause (e)) — the red-path handle
  # ==========================================================================

  @doc """
  Attempt to extend a grant's `expires_at`. This ALWAYS fails with
  `{:error, :no_renew_in_place}` — the grant model ships no renew path (clause
  (e)). This function exists ONLY so the red-path test can prove that extending a
  window is refused; there is no code path anywhere that mutates `expires_at`.

  Re-access requires a fresh `request/1` + `approve/2`.
  """
  @spec attempt_extend(binary(), DateTime.t()) :: {:error, :no_renew_in_place}
  def attempt_extend(_grant_id, _new_expires_at) do
    {:error, :no_renew_in_place}
  end

  # ==========================================================================
  # Samen.Reveal.Grant behaviour — operator-class actor gate
  # ==========================================================================

  @impl Samen.Reveal.Grant
  def granted?(%Context{actor: actor, subject_id: subject_id}) when is_binary(subject_id) do
    # T4.4 clause (d): a SUSPENDED operator (breadth-budget breach) is denied on
    # EVERY reveal path, including the routine grant path — even a live grant does
    # not authorize a suspended operator. suspended?/2 fails closed (treats an
    # unreachable suspension table as suspended), so an ambient DB failure cannot
    # silently disable the gate.
    not Samen.OperatorPlane.Suspension.suspended?(actor) and active?(actor, subject_id)
  end

  # No subject scope in the context ⇒ cannot resolve a grant ⇒ deny (fail closed).
  def granted?(%Context{}), do: false

  # ==========================================================================
  # Audit (clause (f)) — plain rows now; hash chain is Phase 4 (G4)
  # ==========================================================================

  @doc """
  Write a reveal-grant lifecycle audit row AND a corresponding `aud_event` row
  (T2.2 migration: grant lifecycle events write to the append-only event tier
  carrying tokens only).

  Both writes share the caller's transaction context where `r` is already in a
  transaction; the `aud_event` insert is a second INSERT in the same connection.
  If the `aud_event` table does not yet exist (e.g. in tests that have not run
  the T2.2 migration), the write is skipped gracefully — the `rvl_reveal_audit`
  row always lands.

  The `aud_event` row carries ONLY opaque/token-safe fields:
    * `event_type` — "grant_lifecycle"
    * `subject_id` — the subject's UUID / token (NOT plaintext PII)
    * `actor_id`   — the operator actor id (NOT plaintext name)
    * `correlation_id` — the request or grant UUID
    * `detail`     — operator-authored lifecycle metadata (event name, outcome token)
  """
  @spec write_audit(module(), map()) :: {:ok, RevealAudit.t()} | {:error, term}
  def write_audit(r, attrs) do
    result = r.insert(audit_changeset(attrs))

    # Also emit to the aud_event tier AND the T4.3 hash chain (grant lifecycle events
    # are mirrored to the append-only event/audit tier carrying tokens only, and sealed
    # into the tamper-evident, tenant-readable chain the operator cannot edit — ADR-002).
    # The T2.2/T4.3 migrations ensure the tables exist before this code runs; the writer
    # degrades gracefully (aud_event lands, chain skipped) if aud_chain is not deployed.
    Samen.AuditChain.Writer.write(r, %{
      # Reveal/grant events ride the subject's org chain when the caller supplies an
      # org_id; otherwise the reserved "__global__" operator chain (ADR-002 §2.1).
      org_id: attrs[:org_id] || attrs["org_id"] || Samen.AuditChain.global_org(),
      event_type: "grant_lifecycle",
      subject_id: attrs[:subject_id] || attrs["subject_id"],
      actor_id: attrs[:actor_id] || attrs["actor_id"],
      correlation_id:
        attrs[:grant_id] || attrs[:request_id] || attrs["grant_id"] || attrs["request_id"],
      detail:
        "event=#{attrs[:event] || attrs["event"]} " <>
          "#{(attrs[:detail] || attrs["detail"] || "") |> String.trim()}",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })

    # The return value is always the primary rvl_reveal_audit result.
    result
  end

  @doc "List audit rows for a subject, newest first (for tests / operator UI)."
  @spec audit_for(String.t(), keyword()) :: [RevealAudit.t()]
  def audit_for(subject_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())

    r.all(
      from(a in RevealAudit,
        where: a.subject_id == ^subject_id,
        order_by: [desc: a.recorded_at]
      )
    )
  end

  # ==========================================================================
  # Internal
  # ==========================================================================

  defp grant_changeset(attrs) do
    %RevealGrant{}
    |> Ecto.Changeset.cast(attrs, [
      :id,
      :request_id,
      :subject_id,
      :requestor_id,
      :granted_by,
      :reason,
      :resource,
      :action,
      :expires_at,
      :inserted_at,
      :updated_at
    ])
    |> Ecto.Changeset.validate_required([
      :request_id,
      :subject_id,
      :requestor_id,
      :granted_by,
      :reason,
      :expires_at
    ])
    # Surface the DB CHECK as a changeset error rather than a raw exception when
    # possible; the constraint name matches the migration.
    |> Ecto.Changeset.check_constraint(:granted_by,
      name: :rvg_distinct_party,
      message: "granted_by must differ from requestor_id (distinct-party approval)"
    )
  end

  defp audit_changeset(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %RevealAudit{}
    |> Ecto.Changeset.cast(Map.put_new(attrs, :recorded_at, now), [
      :event,
      :subject_id,
      :actor_id,
      :request_id,
      :grant_id,
      :detail,
      :recorded_at
    ])
    |> Ecto.Changeset.validate_required([:event, :subject_id])
  end

  defp actor_id(actor) when is_binary(actor), do: actor
  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(actor), do: to_string(actor)

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end
end
