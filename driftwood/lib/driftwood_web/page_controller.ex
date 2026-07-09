defmodule DriftwoodWeb.PageController do
  @moduledoc """
  The Driftwood landing + health endpoints.

  `/` REDIRECTS to the operator dashboard (`/operator/accounts`) — ADR-013 §3: you land as a
  Driftwood Ops (SaaS-staff) employee looking at all five tenant accounts, zero params typed.
  The operator plane is cross-tenant and needs no tenant org, so the landing has no dead-end.
  `/healthz` returns `ok` (the liveness probe the boot check curls) — unchanged.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  def index(conn, _params) do
    redirect(conn, to: "/operator/accounts")
  end

  def healthz(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
