defmodule Samen.Auth.SessionList do
  @moduledoc """
  ADR-035 §4.3/§5 A4 — the Settings/Security session list read: every LIVE
  (`revoked_at IS NULL` and unexpired) `Identity.Session` row for a
  credential, most-recently-created first, carrying exactly the non-PII
  metadata §4.3 allows on the row (`device_label`, `inserted_at`
  ["created"], `last_seen_at`) — never a raw user-agent, never an IP.
  """

  require Ash.Query

  @doc """
  List `credential_id`'s live sessions, newest (`inserted_at`) first.
  Expired-but-not-yet-revoked rows are excluded (they are functionally dead —
  `Samen.Auth.SessionResolve.resolve/2` already refuses them).
  """
  @spec list_live(module(), String.t()) :: [term()]
  def list_live(session_mod, credential_id) when is_binary(credential_id) do
    now = DateTime.utc_now()

    session_mod
    |> Ash.Query.filter(credential_id == ^credential_id and is_nil(revoked_at) and expires_at > ^now)
    |> Ash.Query.select([:id, :device_label, :last_seen_at, :expires_at, :inserted_at, :credential_id])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  end
end
