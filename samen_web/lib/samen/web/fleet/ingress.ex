defmodule Samen.Web.Fleet.Ingress do
  @moduledoc """
  The **app-side** (reporting-side) fleet ingress (ADR-044 §4.4a): `GET
  /fleet/health` (the mode-A/B health probe) and `POST /fleet/directive` (the
  cockpit→app directive receiver, both modes).

  Verifies every inbound request against `Samen.Fleet.LocalCredential` — what
  THIS app holds about itself. NEVER touches `Samen.Fleet.Registry` or any
  `flt_*` table (that is cockpit-side; see `Samen.Web.Fleet.CockpitIngress`).

  Fail-honest (§4.7, RP-J-10): no local credential configured ⇒ `503`, empty
  body — never a `200` with an empty-looking-healthy report.
  """

  import Plug.Conn

  alias Samen.Fleet.{Crypto, LocalCredential}

  @doc "`GET /fleet/health` — verify + return the current FleetReport."
  @spec health(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def health(conn, opts) do
    host = Keyword.fetch!(opts, :otp_app)

    case LocalCredential.fetch(host) do
      {:error, :not_configured} ->
        respond(conn, 503, "")

      {:ok, credential} ->
        raw_body = ""

        case verify_inbound(conn, credential, raw_body) do
          :ok ->
            report = build_report(host, opts)
            json_body = Jason.encode!(Samen.Fleet.Report.to_wire(report))

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, json_body)
            |> halt()

          {:error, _reason} ->
            respond(conn, 401, "")
        end
    end
  end

  @doc """
  `POST /fleet/directive` — verify + receive a directive. Per ADR §7 (J4), the
  precedence-composition / flag-engine application is T84's; this endpoint
  authenticates the push, structurally validates the envelope shape, and
  acknowledges with the revision it received (an honest `applied_revision: 0`
  when no local applier seam is configured — never a fabricated "applied").
  """
  @spec directive(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def directive(conn, opts) do
    host = Keyword.fetch!(opts, :otp_app)

    case LocalCredential.fetch(host) do
      {:error, :not_configured} ->
        respond(conn, 503, "")

      {:ok, credential} ->
        raw_body = Samen.Web.Webhook.RawBodyReader.raw_body(conn)

        case verify_inbound(conn, credential, raw_body) do
          :ok ->
            case Jason.decode(raw_body) do
              {:ok, %{"fleet_revision" => revision, "target" => _target} = directive}
              when is_integer(revision) ->
                applied = apply_directive(host, directive)
                body = Jason.encode!(%{"applied_revision" => applied})

                conn
                |> put_resp_content_type("application/json")
                |> send_resp(202, body)
                |> halt()

              _ ->
                respond(conn, 422, "")
            end

          {:error, _reason} ->
            respond(conn, 401, "")
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Verification — mode A (shared secret) or mode B (cockpit's public key)
  # ---------------------------------------------------------------------------

  # Fix round (MED, ATK-7): nonce-cache consumption now happens AFTER
  # signature verification, matching the cockpit side
  # (`Samen.Fleet.Registry.verify_and_ingest_heartbeat/2`, which already got
  # this ordering right). Previously an entirely UNAUTHENTICATED request
  # (any signature, even a garbage one) still wrote an ETS row via
  # `NonceCache.check_and_put/2` before the signature was ever checked — an
  # unauthenticated caller could burn/poison a victim's {kid, nonce} pair, or
  # simply flood `Samen.Fleet.NonceCache`'s uncapped table + its per-call
  # full-table sweep, on an unrate-limited route. The signature must be valid
  # BEFORE a request gets to consume the anti-replay budget.
  defp verify_inbound(conn, credential, raw_body) do
    with {:ok, header} <- fetch_auth_header(conn),
         {:ok, fields} <- Crypto.parse_header(header),
         true <- Crypto.fresh_timestamp?(fields.ts) || {:error, :stale_timestamp} do
      signing_input =
        Crypto.signing_input(
          conn.method,
          conn.request_path,
          fields.ts,
          fields.nonce,
          Crypto.body_digest(raw_body)
        )

      with :ok <- verify_signature(credential, signing_input, fields.sig) do
        Samen.Fleet.NonceCache.check_and_put(fields.kid, fields.nonce)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_signature(%{kind: :shared_secret, secret: secret}, signing_input, sig_hex) do
    if Crypto.verify_hmac(secret, signing_input, sig_hex) do
      :ok
    else
      {:error, :bad_signature}
    end
  end

  defp verify_signature(%{kind: :ed25519, cockpit_public_key: pub}, signing_input, sig_hex) do
    with {:ok, sig} <- Base.decode16(sig_hex, case: :mixed),
         true <- Crypto.verify_ed25519(pub, signing_input, sig) do
      :ok
    else
      _ -> {:error, :bad_signature}
    end
  end

  defp verify_signature(_credential, _signing_input, _sig), do: {:error, :bad_signature}

  defp fetch_auth_header(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] -> {:ok, header}
      [] -> {:error, :missing_header}
    end
  end

  defp build_report(host, opts) do
    app_id = Keyword.get(opts, :app_id) || local_app_id(host)
    Samen.Fleet.Report.build(app_id: app_id)
  end

  # Mode B carries a cockpit-assigned `app_id` (from enroll). Mode A has no
  # enroll step — the app never learns a cockpit-assigned id — so it falls back
  # to a stable, UUID-SHAPED synthetic id (schema conformance only; the cockpit
  # already knows which app it queried, by `base_url`).
  defp local_app_id(host) do
    case LocalCredential.fetch(host) do
      {:ok, %{app_id: app_id}} when is_binary(app_id) -> app_id
      _ -> Samen.Fleet.Report.synthetic_app_id("mode-a:" <> Atom.to_string(host))
    end
  end

  # Host-configurable applier seam (§7, T84's engine). Absent ⇒ honestly
  # "not applied" (revision 0), never a fabricated apply.
  defp apply_directive(host, directive) do
    case Application.get_env(host, :fleet_directive_applier) do
      {mod, fun, args} -> apply(mod, fun, args ++ [directive])
      nil -> 0
    end
  end

  defp respond(conn, status, body), do: conn |> send_resp(status, body) |> halt()
end
