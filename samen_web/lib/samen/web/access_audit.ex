defmodule Samen.Web.AccessAudit do
  @moduledoc """
  The audit line of a tenant-plane BULK READ: a CSV export (`csv_export`) or a file-bytes download (`file_download`).
  Both hand the person a copy of the org's data in the clear, so each is recorded through the same tamper-evident
  sink the other governed accesses use (`Samen.AuditChain.Writer`, as `Samen.Web.SampleData` and the DSAR export do):
  token-only (actor id, org, a file id, a count, a bounded outcome; never a row, a value or a file name).

  ## Fail-honest

  A delivery is gated on its audit line, as the DSAR export is (O9): `record/5` returns `{:error, :audit_unavailable}`
  when the line could not be written, and the controller then answers 503 and delivers nothing. A REFUSAL (403, 413,
  422) is recorded best-effort: it has already delivered nothing, so a failed line there is reported by name
  (`Samen.Observability.Failure`) but cannot refuse anything further.

  The repo is the mount's unless `config :samen_web, Samen.Web.AccessAudit, repo: Mod` names another (the seam the
  fault tests use to make the write fail).
  """

  @type kind :: :csv_export | :file_download

  @doc """
  Record one access. `attrs`: `:actor_id` (the resolved user, or the principal that was refused), `:subject_id` (the
  file id; `nil` for a CSV), `:resource` (a validated resource name), `:rows` / `:bytes` (the size delivered) and
  `:outcome` (`:ok` or the refusal: `:denied`, `:quarantined`, `:operator_refused`, `:too_large`, `:failed`), `:limit`.
  """
  @spec record(Samen.Web.Mount.t(), kind(), String.t() | nil, map()) :: :ok | {:error, :audit_unavailable}
  def record(mount, kind, org_id, attrs) when kind in [:csv_export, :file_download] and is_map(attrs) do
    repo = Application.get_env(:samen_web, __MODULE__, [])[:repo] || mount.repo

    result =
      Samen.AuditChain.Writer.write(repo, %{
        org_id: org_id,
        event_type: Atom.to_string(kind),
        subject_id: stringify(attrs[:subject_id]),
        actor_id: stringify(attrs[:actor_id]),
        detail: detail(kind, attrs),
        occurred_at: DateTime.utc_now()
      })

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Samen.Observability.Failure.report_write(:access_audit, org_id, reason)
        {:error, :audit_unavailable}
    end
  rescue
    e ->
      Samen.Observability.Failure.report_write(:access_audit, org_id, e)
      {:error, :audit_unavailable}
  end

  @doc "Record a refusal (best effort): nothing was delivered, so a failed line cannot refuse more. Always `:ok`."
  @spec record_refusal(Samen.Web.Mount.t(), kind(), String.t() | nil, map()) :: :ok
  def record_refusal(mount, kind, org_id, attrs) do
    _ = record(mount, kind, org_id, attrs)
    :ok
  end

  # `event=<kind> [resource=R] [rows=N] [bytes=N] outcome=<o> [limit=N]`: enums, ids and counts only.
  defp detail(kind, attrs) do
    [
      "event=#{kind}",
      attrs[:resource] && "resource=#{attrs[:resource]}",
      attrs[:rows] && "rows=#{attrs[:rows]}",
      attrs[:bytes] && "bytes=#{attrs[:bytes]}",
      "outcome=#{attrs[:outcome] || :ok}",
      attrs[:limit] && "limit=#{attrs[:limit]}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp stringify(nil), do: nil
  defp stringify(v), do: to_string(v)
end
