defmodule Samen.Audit.ImpersonationEmit do
  @moduledoc """
  Shared emission of the P7-F1 impersonation-write `aud_event` (ADR-040 §6.6), used by
  `Samen.Audit.ImpersonationWrite` — the single in-transaction, fail-closed
  `Ash.Resource.Change` (registered `on: [:create, :update, :destroy]`) that covers EVERY
  impersonated write path: create/update/destroy/archive/restore, single AND bulk
  (bulk_create / bulk_update / bulk_destroy).

  The row is token-only (INV-1): no attribute values, only the mutated record's object-ref
  + the operator/session/org ids. See the change moduledoc for the field layout.
  """

  # The context flag the change sets when it has attached its audit hook, so its own
  # `change/3` + `atomic/3` callbacks never double-add the hook for one changeset.
  def ctx_flag, do: :samen_impersonation_audited

  @doc """
  Write the token-only impersonation-write aud_event. Returns `:ok` or `{:error, reason}`.
  Callers decide the failure posture (the change aborts fail-closed; the notifier logs).
  """
  @spec emit(module(), atom(), term(), map()) :: :ok | {:error, term()}
  def emit(resource, action_name, record, marker) when is_map(marker) do
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)
    org_id = marker[:org_id] && to_string(marker[:org_id])
    operator_id = marker[:operator_id] && to_string(marker[:operator_id])
    session_id = marker[:session_id]
    subject_ref = object_ref(resource, record)

    case Samen.AuditChain.Writer.write(repo, %{
           org_id: org_id || Samen.AuditChain.global_org(),
           event_type: "impersonation_write",
           # The tenant org is the subject of an impersonation event (a bounded UUID),
           # consistent with the session open/close events (Sessions.emit_event/3).
           subject_id: org_id,
           actor_id: operator_id,
           # `aud_correlation_id` is a binary_id — pass the session id only when it is a
           # valid UUID (the production shape from Sessions.open/1). The session is always
           # captured in `detail` too, so a non-UUID session marker never loses attribution
           # and never crashes the write (Ecto would raise on a bad binary_id).
           correlation_id: valid_uuid(session_id),
           detail:
             "event=impersonation_write action=#{action_name} session=#{session_id} " <>
               "subject=#{subject_ref}",
           occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The impersonation marker for an actor map (`%Samen.Scope{}`-derived), or nil."
  def marker_from(%{impersonation: %{session_id: session_id} = m}) when is_binary(session_id),
    do: m

  def marker_from(_), do: nil

  # Test-only fault seam (like `Samen.Kms.FileBacked.simulate_outage/1`): when armed, the
  # audit write is treated as failing so the fail-closed / atomicity red-path can prove an
  # impersonated write ABORTS when its audit cannot be recorded. Defaults off.
  @doc false
  def fault_injected?,
    do: Application.get_env(:samen_core, :impersonation_audit_fault, false) == true

  # Token-only object-ref: `samen:<abbrev>:<record-id>` (an abbrev + a UUID; never PII).
  defp object_ref(resource, %{id: id}),
    do: "samen:#{Samen.Info.abbrev(resource) || "unk"}:#{id}"

  defp object_ref(resource, _), do: "samen:#{Samen.Info.abbrev(resource) || "unk"}:unknown"

  defp valid_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end

  defp valid_uuid(_), do: nil
end
