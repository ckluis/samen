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

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(DriftwoodWeb.Router)
end
