defmodule Samen.Web.Fleet.CockpitIngress do
  @moduledoc """
  The **cockpit-side** fleet ingest (ADR-044 §4.4a): `POST /fleet/enroll` and
  `POST /fleet/heartbeat`. Delegates the registry mutation to
  `Samen.Fleet.Registry`, and owns the ONE piece Registry deliberately does not
  (it is HTTP-agnostic): the §4.4a rate-limit posture and the exact response
  shapes (`204` empty always on a valid heartbeat; byte-identical `429`; no body
  on any auth failure).
  """

  import Plug.Conn

  alias Samen.Fleet.{Attention, Crypto, Registry}
  alias Samen.Web.RateLimit

  @doc """
  `POST /fleet/enroll`. Body: `{"token": "...", "public_key": "..."}` (base64).
  `200 {app_id, cockpit_public_key, heartbeat_interval_s, stale_after_s}` on
  success; `401` generic on ANY failure (unknown/consumed/expired token — one
  outcome, §4.3).
  """
  @spec enroll(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def enroll(conn, opts) do
    ns = Keyword.fetch!(opts, :namespace)
    ip = remote_ip(conn)

    if RateLimit.check(:fleet_enroll, :ip, ip) == :ok do
      case conn.body_params do
        %{"token" => token, "public_key" => public_key}
        when is_binary(token) and is_binary(public_key) ->
          case Registry.consume_enrollment(ns, token, public_key) do
            {:ok, result} ->
              json(conn, 200, %{
                "app_id" => result.app_id,
                "cockpit_public_key" => result.cockpit_public_key,
                "heartbeat_interval_s" => result.heartbeat_interval_s,
                "stale_after_s" => result.stale_after_s
              })

            {:error, :invalid_token} ->
              respond(conn, 401, "")
          end

        _ ->
          respond(conn, 422, "")
      end
    else
      respond(conn, 429, "")
    end
  end

  @doc """
  `POST /fleet/heartbeat`. `204 No Content`, EMPTY body, ALWAYS (ADR §4.6 — the
  zero-read-capability claim's structural anchor, RP-J-2). Every failure is
  `401`/`409`/`403`/`422`/`429` with an EMPTY body — never a response channel to
  read through.

  ## Fix round (BLOCKER-1, §4.4a starvation)

  The pre-crypto flood gate is now a NON-INCREMENTING peek
  (`RateLimit.over_limit?/3`) — it runs before credential lookup (so an
  unknown `kid` and a known one look identical) but does NOT consume the
  app's real heartbeat budget just by being asked. The `:fleet_heartbeat`
  bucket is charged (incremented) ONLY on the `{:ok, _report}` path, i.e.
  only after a signature has been verified valid and the report stored. A
  signature-invalid request therefore NEVER touches this bucket at all — it
  can consume only the separate, much-smaller `:fleet_heartbeat_bad_sig`
  bucket (unchanged below). This is what makes "N bad-sig requests followed
  by 1 good heartbeat → the good one still 204" hold (RP-J-13, corrected).
  """
  @spec heartbeat(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def heartbeat(conn, opts) do
    ns = Keyword.fetch!(opts, :namespace)
    raw_body = Samen.Web.Webhook.RawBodyReader.raw_body(conn)

    with {:ok, header} <- fetch_auth_header(conn),
         {:ok, %{kid: kid} = fields} <- Crypto.parse_header(header),
         :ok <- flood_peek(kid),
         {:ok, payload} <- Jason.decode(raw_body) do
      result =
        Registry.verify_and_ingest_heartbeat(ns, %{
          kid: kid,
          v: fields.v,
          ts: fields.ts,
          nonce: fields.nonce,
          sig: fields.sig,
          method: conn.method,
          path: conn.request_path,
          raw_body: raw_body,
          payload: payload
        })

      handle_heartbeat_result(conn, kid, result)
    else
      {:error, :rate_limited} -> respond(conn, 429, "")
      _ -> respond(conn, 401, "")
    end
  end

  defp handle_heartbeat_result(conn, kid, {:ok, _report}) do
    # Charge the REAL heartbeat budget only now — a genuinely valid, stored
    # heartbeat. Bad-signature traffic never reaches this clause, so it never
    # increments this bucket (BLOCKER-1 fix — was previously charged
    # pre-crypto by `flood_gate/1`, which starved the app's own budget).
    case RateLimit.check(:fleet_heartbeat, :kid, kid) do
      :ok -> respond(conn, 204, "")
      {:error, :rate_limited} -> respond(conn, 429, "")
    end
  end

  # "Presented but never authenticated" outcomes (§4.4a's signature_valid?
  # == false class): a forged signature, an unknown kid (no such credential),
  # and a retired key version all mean the presenter never proved it holds a
  # live credential for this app. ALL THREE route through the SAME small,
  # separate bad-sig bucket — never the real :fleet_heartbeat budget (BLOCKER-1)
  # — and, once THAT bucket's own (small) limit trips, respond 429 instead of
  # 401 (still byte-identical: empty body, no distinguishing header) and raise
  # the :heartbeat_rejected attention entry.
  defp handle_heartbeat_result(conn, kid, {:error, reason})
       when reason in [:bad_signature, :unknown_kid, :retired] do
    RateLimit.record_failure(:fleet_heartbeat_bad_sig, :kid, kid)

    if RateLimit.over_limit?(:fleet_heartbeat_bad_sig, :kid, kid) do
      Attention.raise_entry(:heartbeat_rejected, kid)
      respond(conn, 429, "")
    else
      respond(conn, 401, "")
    end
  end

  defp handle_heartbeat_result(conn, _kid, {:error, :replayed}), do: respond(conn, 409, "")
  defp handle_heartbeat_result(conn, _kid, {:error, :app_id_mismatch}), do: respond(conn, 403, "")

  defp handle_heartbeat_result(conn, _kid, {:error, reasons}) when is_list(reasons),
    do: respond(conn, 422, "")

  defp handle_heartbeat_result(conn, _kid, {:error, _reason}), do: respond(conn, 401, "")

  # 429-as-existence-oracle mitigation (§4.4a): runs BEFORE credential lookup,
  # keyed on the PRESENTED kid whether or not it resolves — byte-identical 429
  # in every over-limit case (no body, no Retry-After distinguishing anything).
  # NON-INCREMENTING (over_limit?/3, the shipped :webhook_bad_sig peek pattern)
  # — a PEEK never charges the bucket, so this gate on its own cannot be used
  # to starve a `kid`'s budget; only `handle_heartbeat_result/3`'s `{:ok, _}`
  # clause (above) ever increments it.
  defp flood_peek(kid) do
    if RateLimit.over_limit?(:fleet_heartbeat, :kid, kid) do
      {:error, :rate_limited}
    else
      :ok
    end
  end

  defp fetch_auth_header(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] -> {:ok, header}
      [] -> {:error, :missing_header}
    end
  end

  defp remote_ip(%Plug.Conn{remote_ip: ip}), do: ip |> :inet.ntoa() |> to_string()

  defp respond(conn, status, body), do: conn |> send_resp(status, body) |> halt()

  defp json(conn, status, map) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(map))
    |> halt()
  end
end
