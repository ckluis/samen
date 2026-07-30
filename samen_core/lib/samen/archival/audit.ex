defmodule Samen.Archival.Audit do
  @moduledoc """
  Governance-audit sink for archive/restore (ADR-040 §5.2, T36 c4). Writes a
  token/id-only `record_archived` / `record_restored` event through
  `Samen.AuditChain.Writer.write/2` on the resource's own repo, inside the caller's
  action transaction (called from an `after_action` hook).

  Detail is `resource=<Module> action=<name>` — enum/id-only, never subject PII;
  it still passes `Samen.PiiReasonScan` at the chain boundary. `subject_id` is the
  opaque record id; `actor_id` is the opaque governed actor id (nil-safe).
  """

  @doc "Second/usec-precision now for `archived_at` writes."
  @spec now() :: DateTime.t()
  def now, do: DateTime.utc_now()

  @doc """
  Emit the archive/restore governance event. Best-effort at the chain layer
  (`Writer.write/2` gracefully skips the hash chain if a host has not migrated
  `aud_chain`); the `aud_event` row always lands. Returns `:ok`.
  """
  @spec write(Ash.Changeset.t(), Ash.Resource.record(), String.t()) :: :ok
  def write(changeset, record, event_type) do
    repo = AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)

    _ =
      Samen.AuditChain.Writer.write(repo, %{
        org_id: org_id(changeset, record),
        event_type: event_type,
        subject_id: stringify(real(Map.get(record, :id))),
        actor_id: actor_id(changeset),
        detail: "resource=#{inspect(changeset.resource)} action=#{action_name(changeset)}",
        occurred_at: now()
      })

    :ok
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
