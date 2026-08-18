defmodule DriftwoodWeb.Endpoint do
  @moduledoc """
  The Driftwood Phoenix Endpoint (T5.3 clause (d)) — serves the tenant plane + operator
  plane LiveViews over localhost.

  Local-only: `config :driftwood, DriftwoodWeb.Endpoint, http: [port: 4010]`. The
  Fly.io + Neon target is an OPERATOR TODO (see `docs/driftwood-dogfood.md` "deploy
  seam"): a real deploy injects `secret_key_base` / DB creds from the environment,
  fronts this endpoint with TLS, and points `DATABASE_URL` at a Neon branch. Here it
  runs on `http://localhost:4010` against local Postgres.
  """
  use Phoenix.Endpoint, otp_app: :driftwood

  @session_options [
    store: :cookie,
    key: "_driftwood_key",
    signing_salt: "driftwood_sess_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # ADR-009 + ADR-042 C3: serve the samen_web UI kit stylesheet AND the vendored Phoenix
  # LiveView JS client at `/assets/*`, all from dependency priv (never a driftwood-local
  # copy). `from: {:samen_web, ...}` / `{:phoenix, ...}` / `{:phoenix_live_view, ...}`
  # resolve via `:code.priv_dir/1`; serving the framework bundles from the deps' OWN priv
  # makes client/server version skew structurally impossible. Each clause is a scoped
  # `only:` allowlist (no directory-wide exposure) so nothing can shadow an app route.
  plug(Plug.Static, at: "/assets", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js))

  plug(Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:samen_web, "priv/static/assets"},
    only: ~w(samen_ui.css app.js fonts)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    # ADR-044 (T82 fix round): required for POST /fleet/directive's signature
    # verification (Samen.Web.Fleet.Ingress needs the EXACT signed bytes,
    # which Plug.Parsers otherwise discards after decoding). Same body_reader
    # every samen_webhook_routes/1 host wires; harmless for every other route
    # (it only caches bytes alongside the normal parse).
    body_reader: {Samen.Web.Webhook.RawBodyReader, :read_body, []}
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(DriftwoodWeb.Router)
end
