defmodule DriftwoodWeb.PageController do
  @moduledoc """
  The Driftwood landing + health endpoints.

  `/` REDIRECTS to the operator dashboard (`/operator/accounts`) — ADR-013 §3: you land as a
  Driftwood Ops (SaaS-staff) employee looking at all five tenant accounts, zero params typed.
  The operator plane is cross-tenant and needs no tenant org, so the landing has no dead-end.
  `/healthz` returns `ok` (the LIVENESS probe the boot check curls). `/readyz` is the
  READINESS probe (WS-F1 / F1.2) — 200 only when Postgres, the KMS wrapped-DEK store, and
  Oban all answer (`Samen.Web.Readiness`), else 503; the deploy traffic gate rides it.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  def index(conn, _params) do
    redirect(conn, to: "/operator/accounts")
  end

  def healthz(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  def readyz(conn, _params) do
    case Samen.Web.Readiness.check(repo: Driftwood.Repo) do
      {:ok, _checks} ->
        send_resp(conn, 200, "ready")

      {:error, checks} ->
        body =
          Enum.map_join(checks, "\n", fn
            {component, :ok} -> "#{component}: ok"
            {component, {:error, _reason}} -> "#{component}: FAIL"
          end)

        send_resp(conn, 503, "not ready\n" <> body)
    end
  end
end
