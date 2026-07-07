defmodule DriftwoodWeb.PageController do
  @moduledoc """
  The Driftwood landing + health endpoints (T5.3 clause (d) — boot/curl evidence).

  `/` renders a plain HTML index that links the two planes. `/healthz` returns `ok` (the
  liveness probe the boot check curls).
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  def index(conn, _params) do
    html(conn, """
    <!DOCTYPE html>
    <html><head><title>Driftwood — freight brokerage on Samen</title></head>
    <body>
      <h1>Driftwood</h1>
      <p>Phase-5 reference vertical (freight brokerage) on the Samen substrate.</p>
      <ul>
        <li><a href="/broker?panel=dashboard">Broker console (tenant plane)</a></li>
        <li><a href="/operator/impersonate">Operator — masked impersonation</a></li>
        <li><a href="/operator/aggregate">Operator — cross-tenant aggregate (token-blind)</a></li>
      </ul>
    </body></html>
    """)
  end

  def healthz(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
