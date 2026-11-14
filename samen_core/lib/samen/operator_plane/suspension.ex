defmodule Samen.OperatorPlane.SuspensionRow do
  @moduledoc """
  The per-operator suspension flag row (T4.4 clause (d)). One row per suspended
  operator; the presence of a non-cleared row is the suspension.

  Abbrev-prefixed (`osp_*`) per the self-qualifying-storage idiom. Plain Ecto
  schema (kernel infra consulted by the reveal/impersonation/break-glass deny
  paths), mirroring the reveal-grant / impersonation schema decision.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true, source: :osp_id}
  schema "osp_operator_suspension" do
    field(:operator_id, :string, source: :osp_operator_id)
    field(:reason, :string, source: :osp_reason)
    field(:suspended_at, :utc_datetime_usec, source: :osp_suspended_at)
    field(:cleared_at, :utc_datetime_usec, source: :osp_cleared_at)
    field(:inserted_at, :utc_datetime_usec, source: :osp_inserted_at)
    field(:updated_at, :utc_datetime_usec, source: :osp_updated_at)

    # Not a column (no migration): how the suspension's audit entry stands on the row `suspend/1` returns.
    # `:written` (in the chain), `:pending` (the chain write failed; a durable local entry awaits the reconciler)
    # or `:lost` (the chain write AND the local entry both failed; reported, but nothing durable remains).
    # `:unknown` is a row this call did not write the audit for (a loaded or already-suspended row): it must not claim
    # `:written`.
    field(:audit, Ecto.Enum, values: [:written, :pending, :lost, :unknown], default: :unknown, virtual: true)
  end
end

defmodule Samen.OperatorPlane.Suspension do
  @moduledoc """
  Per-operator **auto-suspend** (T4.4 clause (d); doc "honest edges" break-glass
  bullet — the breadth budget's enforcement teeth).

  When an operator exceeds their per-window **breadth budget** (N distinct subjects
  revealed — see `Samen.BreakGlass.Budget`), they are auto-suspended: a row is
  written to `osp_operator_suspension` and an audit event is emitted. While
  suspended, **every reveal path denies for that operator — including break-glass**
  (there is no emergency override of a suspension; the suspension IS the response to
  abuse). Re-enabling requires an explicit operator-plane `clear/2` (a distinct
  action, deliberately manual — not time-based, so a runaway loop cannot simply wait
  it out).

  ## Single load-bearing check

  `suspended?/2` is the one predicate consulted by:

    * `Samen.Reveal.Grants.granted?/1` (routine reveal),
    * `Samen.Impersonation.Sessions.open/1` (impersonation),
    * `Samen.BreakGlass.reveal/1` (emergency reveal — checked BEFORE the local
      audit write and BEFORE the KMS call).

  It is fail-closed: if the suspension table cannot be reached, the safe answer is
  "treat as suspended" for the reveal paths (a reveal that cannot confirm the
  operator is un-suspended must deny). See `suspended?/2`'s `:on_error` option.

  ## Configuration

      config :samen_core, :operator_suspension_repo, MyApp.Repo
      # Falls back to :impersonation_repo, then :reveal_grant_repo.
  """

  alias Samen.OperatorPlane.SuspensionRow

  import Ecto.Query, only: [from: 2]

  @doc "The Ecto repo backing the suspension flag. Falls back to impersonation/reveal repo."
  @spec repo() :: module()
  def repo do
    Application.get_env(:samen_core, :operator_suspension_repo) ||
      Application.get_env(:samen_core, :impersonation_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo) ||
      raise "Samen.OperatorPlane.Suspension needs a repo (:operator_suspension_repo)"
  end

  @doc """
  Auto-suspend an operator (T4.4 clause (d)). Idempotent: a second suspend of an
  already-suspended operator is a no-op returning the existing row. Writes an
  `operator_suspended` audit event (token-only) into the append-only tier + the
  T4.3 chain (or, if that write fails, defers it durably; see below).

  `attrs`: `:operator_id` (required), `:reason` (required), optional `:org_id`
  (the chain partition; defaults to `"__global__"` — a platform-scope event),
  `:repo`, `:local_audit_path` (where a deferred audit entry is parked).

  The suspension commits FIRST, whatever happens to the audit. `{:ok, row}` always means the operator IS suspended;
  `row.audit` is `:written`, `:pending` or `:lost` (see `SuspensionRow`); an idempotent re-suspend returns the existing
  row with `:unknown` (this call wrote no audit, and cannot say how the earlier one stands). `{:error, _}` means it was NOT suspended.
  """
  @spec suspend(map()) :: {:ok, SuspensionRow.t()} | {:error, term}
  def suspend(attrs) do
    r = Map.get(attrs, :repo, repo())
    operator_id = fetch!(attrs, :operator_id)
    reason = fetch!(attrs, :reason)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case active_row(r, operator_id) do
      {:error, :unavailable} ->
        {:error, :unavailable}

      {:ok, %SuspensionRow{} = existing} ->
        {:ok, existing}

      {:ok, nil} ->
        row =
          %SuspensionRow{}
          |> Ecto.Changeset.cast(
            %{
              operator_id: operator_id,
              reason: reason,
              suspended_at: now,
              inserted_at: now,
              updated_at: now
            },
            [:operator_id, :reason, :suspended_at, :inserted_at, :updated_at]
          )
          |> Ecto.Changeset.validate_required([:operator_id, :reason, :suspended_at])

        # ASYMMETRIC with `clear/2`. Suspending REMOVES privilege, so it must never wait on (or be undone by) the
        # audit tables: the suspension row commits on its own first. A failed audit write is reported and made
        # durable locally (`Samen.BreakGlass.LocalAudit`, the break-glass deferred-anchor precedent), to be
        # anchored into the chain later by `Samen.BreakGlass.Reconciliation`; the returned row says which.
        # `clear/2` RESTORES privilege and stays atomic with its audit entry (fail closed).
        case insert_suspension(r, row) do
          {:ok, inserted} -> {:ok, audit_after_commit(r, inserted, attrs, reason)}
          {:error, _} = error -> error
        end
    end
  end

  defp insert_suspension(r, row) do
    case r.insert(row) do
      {:ok, inserted} ->
        {:ok, inserted}

      {:error, failure} ->
        Samen.Observability.Failure.report(:suspension_insert, nil, failure)
        {:error, :unavailable}
    end
  rescue
    e ->
      Samen.Observability.Failure.report(:suspension_insert, nil, e)
      {:error, :unavailable}
  end

  defp audit_after_commit(r, inserted, attrs, reason) do
    operator_id = inserted.operator_id
    org_id = Map.get(attrs, :org_id) || Samen.AuditChain.global_org()

    audited =
      try do
        r.transaction(fn ->
          case emit_audit(r, %{
                 event: "operator_suspended",
                 operator_id: operator_id,
                 org_id: org_id,
                 detail: "reason=#{reason}"
               }) do
            {:ok, _} -> :ok
            {:error, failure} -> r.rollback(failure)
          end
        end)
      rescue
        e ->
          Samen.Observability.Failure.report(:suspension_audit, org_id, e)
          {:error, :audit_unavailable}
      end

    case audited do
      {:ok, :ok} -> %{inserted | audit: :written}
      {:error, _} -> %{inserted | audit: defer_audit(attrs, operator_id, org_id, reason)}
    end
  end

  # The chain write failed (already reported by `emit_audit`). Park the entry on the local hash chain so the
  # reconciler can anchor it; `:lost` only when even that fails, and that is reported by name.
  defp defer_audit(attrs, operator_id, org_id, reason) do
    opts = if path = Map.get(attrs, :local_audit_path), do: [path: path], else: []

    case Samen.BreakGlass.LocalAudit.append(
           %{
             org_id: org_id,
             subject_id: operator_id,
             actor_id: operator_id,
             reason: "reason=#{reason}",
             resource: "operator_suspension",
             action: "operator_suspended",
             kind: "operator_suspension",
             correlation_id: uuid_or_nil(operator_id)
           },
           opts
         ) do
      {:ok, _entry} ->
        :pending

      {:error, failure} ->
        Samen.Observability.Failure.report(:suspension_audit_deferral, org_id, failure)
        :lost
    end
  end

  @doc """
  Clear a suspension (re-enable the operator). Explicit operator-plane action —
  deliberately manual (a suspension is not time-based). Sets `cleared_at`, writes
  an `operator_unsuspended` audit event. Idempotent.
  """
  @spec clear(String.t(), map()) :: {:ok, SuspensionRow.t() | :not_suspended} | {:error, term}
  def clear(operator_id, opts \\ %{}) do
    r = Map.get(opts, :repo, repo())
    actor = Map.get(opts, :cleared_by, "operator:manual")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case active_row(r, operator_id) do
      {:error, :unavailable} ->
        # A failed lookup is not "nothing to clear": the operator may still be suspended.
        {:error, :unavailable}

      {:ok, nil} ->
        {:ok, :not_suspended}

      {:ok, %SuspensionRow{} = row} ->
        r.transaction(fn ->
          with {:ok, updated} <-
                 row
                 |> Ecto.Changeset.change(cleared_at: now, updated_at: now)
                 |> r.update(),
               {:ok, _} <-
                 emit_audit(r, %{
                   event: "operator_unsuspended",
                   operator_id: operator_id,
                   org_id: Map.get(opts, :org_id) || Samen.AuditChain.global_org(),
                   detail: "cleared_by=#{actor}"
                 }) do
            updated
          else
            {:error, failure} -> r.rollback(failure)
          end
        end)
    end
  end

  @doc """
  Is this operator currently suspended? The single load-bearing predicate for
  every reveal path.

  Returns `true` if a non-cleared suspension row exists for the operator.

  Options:
    * `:repo`
    * `:on_error` — what to return if the suspension table cannot be reached.
      Defaults to `true` (fail closed — a reveal that cannot confirm the operator
      is un-suspended MUST deny). Callers that want a different posture pass it
      explicitly, but the reveal paths use the default.
  """
  @spec suspended?(String.t() | term(), keyword()) :: boolean()
  def suspended?(operator, opts \\ []) do
    case status(operator, opts) do
      {:ok, suspended?} -> suspended?
      {:error, :unavailable} -> Keyword.get(opts, :on_error, true)
    end
  end

  @doc """
  `suspended?/2` as a tagged result: `{:ok, boolean}`, or `{:error, :unavailable}` when the suspension table
  cannot be reached. A caller that must TELL the user (a reveal screen) uses this to say "couldn't check" instead of
  "denied"; the reveal paths themselves still use `suspended?/2`, which fails closed. A missing operator id is
  `{:ok, true}` (it cannot be an un-suspended operator).
  """
  @spec status(String.t() | term(), keyword()) :: {:ok, boolean()} | {:error, :unavailable}
  def status(operator, opts \\ []) do
    case operator_id(operator) do
      nil ->
        {:ok, true}

      operator_id ->
        r = Keyword.get(opts, :repo, repo())

        try do
          {:ok,
           r.exists?(
             from(s in SuspensionRow,
               where: s.operator_id == ^operator_id and is_nil(s.cleared_at)
             )
           )}
        rescue
          e ->
            Samen.Observability.Failure.report(:suspension_status, nil, e)
            {:error, :unavailable}
        end
    end
  end

  # ==========================================================================
  # Internal
  # ==========================================================================

  # `{:ok, row | nil}` or `{:error, :unavailable}`: a failed lookup is NOT "no active suspension".
  defp active_row(r, operator_id) do
    {:ok,
     r.one(
       from(s in SuspensionRow,
         where: s.operator_id == ^operator_id and is_nil(s.cleared_at),
         limit: 1
       )
     )}
  rescue
    e ->
      Samen.Observability.Failure.report(:suspension_active_row, nil, e)
      {:error, :unavailable}
  end

  # Emit the suspend/clear event to the append-only tier + the T4.3 chain (tokens
  # only). Best-effort within the caller's connection; a missing aud_event/aud_chain
  # (unmigrated host) degrades gracefully like the other writers.
  defp emit_audit(r, attrs) do
    case Samen.AuditChain.Writer.write(r, %{
           org_id: attrs.org_id,
           event_type: "operator_suspension",
           subject_id: attrs.operator_id,
           actor_id: attrs.operator_id,
           correlation_id: uuid_or_nil(attrs.operator_id),
           detail: "event=#{attrs.event} #{attrs.detail}",
           occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
         }) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Samen.Observability.Failure.report(:suspension_audit, attrs.org_id, reason)
        {:error, :audit_unavailable}
    end
  rescue
    e ->
      Samen.Observability.Failure.report(:suspension_audit, attrs.org_id, e)
      {:error, :audit_unavailable}
  end

  # `aud_correlation_id` is a :binary_id column. An operator id that is not a UUID used to make the whole audit write
  # raise — silently, under the old `rescue _ -> :ok` — so the suspension went unaudited. The event still names the
  # operator as subject and actor; only the (UUID-typed) correlation id is dropped.
  defp uuid_or_nil(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp operator_id(op) when is_binary(op), do: op
  defp operator_id(%{id: id}) when is_binary(id), do: id
  defp operator_id(_), do: nil

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> raise ArgumentError, "missing required key #{inspect(key)}"
    end
  end
end
