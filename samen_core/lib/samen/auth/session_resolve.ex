defmodule Samen.Auth.SessionResolve do
  @moduledoc """
  ADR-035 §4.3/§5 A4 — the read half of the session discipline: given a RAW
  session token (from either cookie — the plain Phoenix session or the
  remember-me cookie both carry the SAME raw token, §4.3), resolve the live
  `Identity.Session` row it names. Revocation is row-level and IMMEDIATE: a
  revoked or expired row resolves to `:error` on the very next request — there
  is no stateless-JWT non-revocability window by design.

  `Samen.Web.Auth.resolve_principal/2` is the web-layer caller (conn/LiveView
  session → this module → `{credential_id, session_id}`).
  """

  require Ash.Query

  alias Samen.Auth.TokenMint

  # Best-effort `last_seen_at` touch is THROTTLED to at most once per window —
  # it never gates auth (a resolve never fails because a touch was skipped),
  # it just avoids a write on every single request (the ApiKey `mark_used`
  # precedent, ADR-035 §4.3).
  @touch_throttle_seconds 5 * 60

  @doc """
  Resolve a RAW session token to its live `Identity.Session` row. `{:ok,
  session}` only when a row's digest matches AND `revoked_at IS NULL` AND
  `expires_at` is in the future — an unknown/revoked/expired token all
  resolve to the SAME `:error`, no distinguishing signal.
  """
  @spec resolve(module(), String.t()) :: {:ok, term()} | :error
  def resolve(session_mod, raw_token) when is_binary(raw_token) do
    now = DateTime.utc_now()
    digest = TokenMint.digest(raw_token)

    session_mod
    |> Ash.Query.filter(token_digest == ^digest and is_nil(revoked_at) and expires_at > ^now)
    |> Ash.Query.limit(1)
    # authz-scope: session AUTH-STEP resolve keyed on the unique token digest — no actor exists
    # until this row resolves (unknown/revoked/expired collapse to the same :error, fail closed)
    |> Ash.read!(authorize?: false)
    |> case do
      [session] -> {:ok, session}
      [] -> :error
    end
  end

  def resolve(_session_mod, _raw_token), do: :error

  @doc """
  Best-effort, throttled `last_seen_at` touch + expiry slide (§4.3: "sessions
  slide"). Skipped entirely (a true no-op) if the row was touched inside the
  throttle window — never raises, never gates the caller's auth outcome.
  """
  @spec touch(module(), term()) :: :ok
  def touch(session_mod, %{id: id, last_seen_at: last_seen_at}) do
    now = DateTime.utc_now()

    if stale?(last_seen_at, now) do
      expires_at = DateTime.add(now, Samen.Auth.SessionCreate.default_ttl_seconds(), :second)

      session_mod
      |> Ash.Query.filter(id == ^id)
      |> Ash.bulk_update!(:touch, %{last_seen_at: now, expires_at: expires_at},
        authorize?: false,
        return_errors?: false
      )
    end

    :ok
  end

  defp stale?(nil, _now), do: true

  defp stale?(%DateTime{} = last_seen_at, now),
    do: DateTime.diff(now, last_seen_at, :second) >= @touch_throttle_seconds
end
