defmodule PawChartWeb.Endpoint do
  @moduledoc """
  The PawChart Phoenix Endpoint — serves the tenant + operator LiveView planes over
  localhost. Mirrors Driftwood's pattern (T5.3 / ADR-009).

  Serves on port 4032 (dev). The inherited CRM/Billing/Support pages come from
  `samen_web` (mounted via `samen_module_routes/3` in `PawChartWeb.Router`); the
  clinical vertical pages are PawChart-local.

  The secret_key_base + live_view signing salt are LOCAL DEV/DOGFOOD constants.
  """
  use Phoenix.Endpoint, otp_app: :pawchart

  @session_options [
    store: :cookie,
    key: "_pawchart_key",
    signing_salt: "pawchart_sess_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # ADR-009: serve the Samen UI kit's stylesheet from the samen_web DEPENDENCY's priv
  # at `/assets/samen_ui.css`. Same file as Driftwood — zero duplication.
  plug(Plug.Static,
    at: "/assets",
    from: {:samen_web, "priv/static/assets"},
    only: ~w(samen_ui.css)
  )

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
  plug(PawChartWeb.Router)
end
