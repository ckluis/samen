defmodule Samen.Archival.Audit do
  @moduledoc """
  Governance-audit sink for archive/restore (ADR-040 §5.2, T36 c4). Writes a
  token/id-only `record_archived` / `record_restored` event through
  `Samen.AuditChain.Writer.write/2` on the resource's own repo, inside the caller's
  action transaction (called from an `after_action` hook).

  STRICT: archiving and restoring are governance state changes the tamper-evident chain must see. The event is written
  inside the action's transaction and a failed write returns `{:error, _}`, which the callers' `after_action` hooks
  hand back so the whole archive/restore rolls back. (Only a failure that does not poison the transaction — an
  unreachable chain probe, a rejected detail — reaches this return at all; a SQL error aborts the transaction itself.)

  Detail is `resource=<Module> action=<name>` — enum/id-only, never subject PII;
  it still passes `Samen.PiiReasonScan` at the chain boundary. `subject_id` is the
  opaque record id; `actor_id` is the opaque governed actor id (nil-safe).
  """

  @doc "Second/usec-precision now for `archived_at` writes."
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()

  @doc """
  Emit the archive/restore governance event. A host that has not migrated `aud_chain` degrades gracefully
  (`Writer.write/2` skips the hash chain; the `aud_event` row still lands). Returns `:ok`, or `{:error,
  :audit_unavailable}` (reported by name) so the caller's transaction rolls back. The repo is the resource's own
  unless `changeset.context[:samen_audit_repo]` names another (the seam the fault tests use).
  """
  @spec write(Ash.Changeset.t(), Ash.Resource.Record.t(), String.t()) :: :ok | {:error, :audit_unavailable}
  def write(changeset, record, event_type) do
    repo = Map.get(changeset.context, :samen_audit_repo) || AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)

    org = org_id(changeset, record)

    # A failed write is reported by name (value-free) AND refuses the archive/restore (the caller rolls back); the
    # Writer never commits a chainless event.
    case Samen.AuditChain.Writer.write(repo, %{
           org_id: org,
           event_type: event_type,
           subject_id: stringify(real(Map.get(record, :id))),
           actor_id: actor_id(changeset),
           detail: "resource=#{inspect(changeset.resource)} action=#{action_name(changeset)}",
           occurred_at: now()
         }) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Samen.Observability.Failure.report(:archival_audit, org, reason)
        {:error, :audit_unavailable}
    end
  end

  # The destroyed/updated record often has only `id` + changed attrs loaded, so
  # `org_id` may be `%Ash.NotLoaded{}`. Fall back to the actor's org (the governed
  # scope), then nil (a plane-global / internal write).
  defp org_id(changeset, record) do
    real(Map.get(record, :org_id)) || actor(changeset)[:org_id]
  end

  defp actor_id(changeset) do
    case actor(changeset)[:id] do
      nil -> nil
      id -> stringify(id)
    end
  end

  defp actor(changeset) do
    case get_in(changeset.context, [:private, :actor]) do
      %{} = a -> a
      _ -> %{}
    end
  end

  # Coerce Ash's unloaded sentinel to nil so it never reaches the audit chain's
  # `to_string/1`.
  defp real(%Ash.NotLoaded{}), do: nil
  defp real(value), do: value

  defp action_name(%{action: %{name: name}}), do: name
  defp action_name(_), do: nil

  defp stringify(nil), do: nil
  defp stringify(v), do: to_string(v)
end
