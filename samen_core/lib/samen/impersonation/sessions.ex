defmodule Samen.Impersonation.Sessions do
  @moduledoc """
  The masked-impersonation session runtime (T4.1; doc §control lead + the two-planes
  block). The operator-plane analogue of `Samen.Reveal.Grants` (T1.6), reusing its
  time-boxed / same-tx-cleanup / no-renew mechanics.

  ## Lifecycle

    1. `open/1` — an operator opens a session scoped to ONE target org, with a
       REQUIRED reason-for-access. This writes an `imp_impersonation_session` row with
       a bounded `expires_at` (minutes-scale default) AND enqueues the `ExpireWorker`
       (scheduled at `expires_at`) **in the same transaction** (mirrors T1.6 clause
       (d)) AND writes an `impersonation` open event to the append-only `aud_event`
       tier (tokens only). A session with no reason is refused (`{:error, :reason_required}`).
    2. reads consult `active?/2` — which DENIES the moment `now() > expires_at`,
       computed against the row (deny-on-read, mirrors T1.6 clause (c)), and denies if
       `closed_at` is set. This is checked PER REQUEST, not per open.
    3. `close/2` — an operator (or the auto-expire worker) closes the session. Sets
       `closed_at` (NOT `expires_at` — no renew-in-place) and writes a close/expiry
       `aud_event` row.
    4. `ExpireWorker` flips `closed_at` at `expires_at` (reconciliation, not the safety
       mechanism — expiry is safe on read regardless).

  ## Every open/close/expiry writes an `aud_event` row (T4.1 clause (d))

  `aud_event` is the append-only, token-only event tier (T2.2). Impersonation events
  carry ONLY:
    * `event_type` — "impersonation" (a bounded enum)
    * `subject_id` — the target `org_id` (a bounded UUID — the org is the "subject" of
      an impersonation event; NOT plaintext PII)
    * `actor_id`   — the operator id (bounded, NOT plaintext name)
    * `correlation_id` — the session UUID
    * `detail`     — the operator-authored reason + lifecycle token (open/close/expired)

  The `no_plaintext_pii` oracle's `AudEvent` tier already asserts this invariant.

  ## Tenant-visible (T4.1 clause (c))

  `list_for_org/2` returns the impersonation sessions against a given org — who
  (`operator_id`), when (`inserted_at`), reason, and expiry. This is the tenant-plane
  read the doc's accountability story requires (a tenant can see who impersonated
  their org, when, and why).

  ## Configuration

      config :samen_core, :impersonation_repo, MyApp.Repo
      # Default impersonation window (minutes). Bounded default, minutes-scale.
      config :samen_core, :impersonation_default_window_minutes, 30
  """

  alias Samen.Impersonation.{Session, ExpireWorker}

  import Ecto.Query, only: [from: 2]

  # A conservative minutes-scale default (doc: "minutes, not a standing entitlement").
  @default_window_minutes 30

  # ==========================================================================
  # Configuration helpers
  # ==========================================================================

  @doc "The Ecto repo backing impersonation sessions. Configure via `:impersonation_repo`."
  @spec repo() :: module()
  def repo do
    Application.get_env(:samen_core, :impersonation_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      raise """
      Samen.Impersonation.Sessions needs a repo. Configure it:

          config :samen_core, :impersonation_repo, MyApp.Repo
      """
  end

  @doc """
  The default impersonation window in minutes (bounded, minutes-scale).
  Configure via `:impersonation_default_window_minutes`; defaults to 30.
  """
  @spec default_window_minutes() :: pos_integer()
  def default_window_minutes do
    Application.get_env(
      :samen_core,
      :impersonation_default_window_minutes,
      @default_window_minutes
    )
  end

  # ==========================================================================
  # 1. Open — reason REQUIRED, single-org, same-tx expire enqueue + audit
  # ==========================================================================

  @doc """
  Open an impersonation session scoped to ONE target `org_id`, with a REQUIRED
  `reason`. Returns `{:ok, %Session{}}`.

  Required attrs:
    * `:operator_id` — the operator-plane actor opening the session (bounded id).
    * `:org_id`      — the ONE target tenant org.
    * `:reason`      — reason-for-access. A blank/missing reason is refused with
      `{:error, :reason_required}` BEFORE any DB write (fail closed).

  Optional:
    * `:window_minutes` — override the bounded default window.
    * `:repo` — override the configured repo.

  The session row INSERT, the `impersonation` open `aud_event`, and the same-tx
  `ExpireWorker` enqueue all ride ONE `Ecto.Multi` / ONE transaction (mirrors T1.6
  clause (d)). If any step fails, the whole thing rolls back — no session, no audit,
  NO job.
  """
  @spec open(map()) :: {:ok, Session.t()} | {:error, term}
  def open(attrs) do
    r = Map.get(attrs, :repo, repo())
    operator_id = fetch!(attrs, :operator_id)
    org_id = fetch!(attrs, :org_id)
    reason = attrs[:reason]

    cond do
      not is_binary(reason) or String.trim(reason) == "" ->
        # Reason-for-access is required (doc §control). Refuse before any write.
        {:error, :reason_required}

      true ->
        do_open(r, operator_id, org_id, reason, attrs)
    end
  end

  defp do_open(r, operator_id, org_id, reason, attrs) do
    window = Map.get(attrs, :window_minutes, default_window_minutes())
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires_at = DateTime.add(now, window * 60, :second)

    session_id = Ecto.UUID.generate()

    session_attrs = %{
      id: session_id,
      operator_id: operator_id,
      org_id: org_id,
      reason: reason,
      expires_at: expires_at,
      inserted_at: now,
      updated_at: now
    }

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:session, session_changeset(session_attrs))
      |> Ecto.Multi.run(:audit, fn r2, _changes ->
        emit_event(r2, "open", %{
          org_id: org_id,
          operator_id: operator_id,
          session_id: session_id,
          reason: reason,
          detail: "expires_at=#{DateTime.to_iso8601(expires_at)}"
        })

        {:ok, :audited}
      end)
      |> Oban.insert(:auto_expire, ExpireWorker.new(%{session_id: session_id},
        scheduled_at: expires_at
      ))

    case r.transaction(multi) do
      {:ok, %{session: session}} -> {:ok, session}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  # ==========================================================================
  # 2. Deny-on-read (per-request expiry check) — mirrors T1.6 clause (c)
  # ==========================================================================

  @doc """
  Is there an ACTIVE, unexpired impersonation session for THIS operator over THIS org?

  Returns `true` only when a session exists whose `operator_id == operator`,
  `org_id == org_id`, `closed_at IS NULL`, and `expires_at > now`. It DENIES the moment
  `now() > expires_at` — computed against the row, with NO dependence on the
  auto-expire job having run (deny-on-read, checked per request). Everything else →
  `false` (fail closed).

  This is the check the impersonation scope's policy must consult on EVERY request, so
  an expired session denies mid-flight (T4.1 red path: "expired session denies
  mid-flight — policy checks expiry per-request, not per-open").
  """
  @spec active?(String.t(), String.t(), keyword()) :: boolean()
  def active?(operator_id, org_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    query =
      from(s in Session,
        where:
          s.operator_id == ^operator_id and
            s.org_id == ^org_id and
            is_nil(s.closed_at) and
            s.expires_at > ^now,
        select: s.id,
        limit: 1
      )

    r.exists?(query)
  end

  @doc """
  Fetch the ACTIVE session struct for `(operator_id, org_id)` at `now`, or `nil`.
  Same deny-on-read semantics as `active?/2`. Used by the scope builder.
  """
  @spec active_session(String.t(), String.t(), keyword()) :: Session.t() | nil
  def active_session(operator_id, org_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    r.one(
      from(s in Session,
        where:
          s.operator_id == ^operator_id and
            s.org_id == ^org_id and
            is_nil(s.closed_at) and
            s.expires_at > ^now,
        order_by: [desc: s.inserted_at],
        limit: 1
      )
    )
  end

  @doc "Fetch a session by id (any state)."
  @spec get(binary(), keyword()) :: Session.t() | nil
  def get(session_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    r.get(Session, session_id)
  end

  # ==========================================================================
  # 3. Close (manual) — sets closed_at only, never expires_at
  # ==========================================================================

  @doc """
  Close a session now. Sets `closed_at` (NOT `expires_at` — no renew-in-place). Writes
  a `close` `aud_event` row. Idempotent (a second close is a no-op).

  Options:
    * `:cause` — "manual" (default) | "expired". A bounded token.
    * `:actor_id` — the operator/worker id recorded on the close event.
    * `:repo` — override the configured repo.
  """
  @spec close(binary(), map()) :: {:ok, Session.t()} | {:error, term}
  def close(session_id, opts \\ %{}) do
    r = Map.get(opts, :repo, repo())
    cause = Map.get(opts, :cause, "manual")
    actor_id = Map.get(opts, :actor_id)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case r.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      %Session{closed_at: nil} = session ->
        {:ok, closed} =
          session
          |> Ecto.Changeset.change(closed_at: now, close_cause: cause, updated_at: now)
          |> r.update()

        emit_event(r, cause_event(cause), %{
          org_id: session.org_id,
          operator_id: actor_id || session.operator_id,
          session_id: session.id,
          reason: session.reason,
          detail: "closed cause=#{cause}"
        })

        {:ok, closed}

      %Session{} = session ->
        # Already closed — idempotent no-op.
        {:ok, session}
    end
  end

  defp cause_event("expired"), do: "expired"
  defp cause_event(_), do: "close"

  # ==========================================================================
  # 4. No renew-in-place — the red-path handle (mirrors T1.6 clause (e))
  # ==========================================================================

  @doc """
  Attempt to extend a session's `expires_at`. This ALWAYS fails with
  `{:error, :no_renew_in_place}` — impersonation ships no renew path. This function
  exists ONLY so the red-path test can prove that extending a window is refused; there
  is no code path anywhere that mutates `expires_at`.

  Re-access requires a fresh `open/1` (a fresh reason).
  """
  @spec attempt_extend(binary(), DateTime.t()) :: {:error, :no_renew_in_place}
  def attempt_extend(_session_id, _new_expires_at) do
    {:error, :no_renew_in_place}
  end

  # ==========================================================================
  # 5. Tenant-visible listing (T4.1 clause (c))
  # ==========================================================================

  @doc """
  List impersonation sessions against `org_id`, newest first — the tenant-plane
  accountability view (who, when, reason, expiry, whether still open).

  Returns a list of plain maps with ONLY tenant-appropriate, non-PII fields:
  `operator_id`, `reason`, `opened_at`, `expires_at`, `closed_at`, `active?`.
  """
  @spec list_for_org(binary(), keyword()) :: [map()]
  def list_for_org(org_id, opts \\ []) do
    r = Keyword.get(opts, :repo, repo())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    r.all(
      from(s in Session,
        where: s.org_id == ^org_id,
        order_by: [desc: s.inserted_at]
      )
    )
    |> Enum.map(fn s ->
      %{
        session_id: s.id,
        operator_id: s.operator_id,
        reason: s.reason,
        opened_at: s.inserted_at,
        expires_at: s.expires_at,
        closed_at: s.closed_at,
        active?: is_nil(s.closed_at) and DateTime.compare(s.expires_at, now) == :gt
      }
    end)
  end

  # ==========================================================================
  # aud_event emission (T4.1 clause (d)) — tokens only
  # ==========================================================================

  @doc """
  Emit an impersonation lifecycle event to the append-only `aud_event` tier
  (tokens only — the target org_id as subject, the operator id as actor, the session
  id as correlation, the reason + lifecycle token as detail). Never plaintext PII.
  """
  @spec emit_event(module(), String.t(), map()) :: {:ok, term} | {:error, term}
  def emit_event(r, lifecycle, attrs) do
    Samen.AuditEvent.insert(r, %{
      event_type: "impersonation",
      # The target ORG is the subject of an impersonation event — a bounded UUID.
      subject_id: attrs[:org_id] && to_string(attrs[:org_id]),
      actor_id: attrs[:operator_id] && to_string(attrs[:operator_id]),
      correlation_id: attrs[:session_id],
      detail:
        "event=#{lifecycle} reason=#{sanitize(attrs[:reason])} " <>
          "#{(attrs[:detail] || "") |> String.trim()}",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  end

  # ==========================================================================
  # Internal
  # ==========================================================================

  defp session_changeset(attrs) do
    %Session{}
    |> Ecto.Changeset.cast(attrs, [
      :id,
      :operator_id,
      :org_id,
      :reason,
      :expires_at,
      :inserted_at,
      :updated_at
    ])
    |> Ecto.Changeset.validate_required([:operator_id, :org_id, :reason, :expires_at])
  end

  # The reason is operator-authored metadata; it is NOT subject PII (it describes WHY
  # the operator opened the session — "customer #1234 reported a billing error"). We
  # keep it as authored but collapse whitespace so the detail token stays single-line.
  defp sanitize(nil), do: ""
  defp sanitize(reason) when is_binary(reason), do: reason |> String.replace(~r/\s+/, " ") |> String.trim()
  defp sanitize(other), do: to_string(other)

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end
end
