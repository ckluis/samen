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
  T4.3 chain.

  `attrs`: `:operator_id` (required), `:reason` (required), optional `:org_id`
  (the chain partition; defaults to `"__global__"` — a platform-scope event),
  `:repo`.
  """
  @spec suspend(map()) :: {:ok, SuspensionRow.t()} | {:error, term}
  def suspend(attrs) do
    r = Map.get(attrs, :repo, repo())
    operator_id = fetch!(attrs, :operator_id)
    reason = fetch!(attrs, :reason)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case active_row(r, operator_id) do
      %SuspensionRow{} = existing ->
        {:ok, existing}

      nil ->
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

        with {:ok, inserted} <- r.insert(row) do
          emit_audit(r, %{
            event: "operator_suspended",
            operator_id: operator_id,
            org_id: Map.get(attrs, :org_id) || Samen.AuditChain.global_org(),
            detail: "reason=#{reason}"
          })

          {:ok, inserted}
        end
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
      nil ->
        {:ok, :not_suspended}

      %SuspensionRow{} = row ->
        with {:ok, updated} <-
               row
               |> Ecto.Changeset.change(cleared_at: now, updated_at: now)
               |> r.update() do
          emit_audit(r, %{
            event: "operator_unsuspended",
            operator_id: operator_id,
            org_id: Map.get(opts, :org_id) || Samen.AuditChain.global_org(),
            detail: "cleared_by=#{actor}"
          })

          {:ok, updated}
        end
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
    operator_id = operator_id(operator)
    r = Keyword.get(opts, :repo, repo())
    on_error = Keyword.get(opts, :on_error, true)

    if is_nil(operator_id) do
      # No resolvable operator id → cannot be an un-suspended operator → deny.
      on_error
    else
      try do
        r.exists?(
          from(s in SuspensionRow,
            where: s.operator_id == ^operator_id and is_nil(s.cleared_at)
          )
        )
      rescue
        _ -> on_error
      end
    end
  end

  # ==========================================================================
  # Internal
  # ==========================================================================

  defp active_row(r, operator_id) do
    r.one(
      from(s in SuspensionRow,
        where: s.operator_id == ^operator_id and is_nil(s.cleared_at),
        limit: 1
      )
    )
  rescue
    _ -> nil
  end

  # Emit the suspend/clear event to the append-only tier + the T4.3 chain (tokens
  # only). Best-effort within the caller's connection; a missing aud_event/aud_chain
  # (unmigrated host) degrades gracefully like the other writers.
  defp emit_audit(r, attrs) do
    Samen.AuditChain.Writer.write(r, %{
      org_id: attrs.org_id,
      event_type: "operator_suspension",
      subject_id: attrs.operator_id,
      actor_id: attrs.operator_id,
      correlation_id: attrs.operator_id,
      detail: "event=#{attrs.event} #{attrs.detail}",
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    })
  rescue
    _ -> :ok
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
