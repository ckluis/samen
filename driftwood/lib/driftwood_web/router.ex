defmodule DriftwoodWeb.Router do
  @moduledoc """
  The Driftwood host router (T5.3). Mounts the two planes as LiveViews over localhost:

    * TENANT plane — `/broker` (`DriftwoodWeb.BrokerLive`): the brokerage console
      (rollup-backed dashboard, load board, driver roster w/ FMCSA status, settlements).
    * OPERATOR plane:
      * `/operator/impersonate` (`DriftwoodWeb.OperatorImpersonationLive`) — masked
        impersonation over ONE tenant: real load board / driver roster, PII ••••, plus
        the second-party reveal control.
      * `/operator/aggregate` (`DriftwoodWeb.OperatorDashboardLive`) — the token-blind
        cross-tenant load-volume / MRR dashboard (NO PII).

  `/` is a plain landing/health page (used for the boot curl check). `/healthz` returns
  `ok`. The org/operator identity is passed as query params for the LOCAL dogfood — a
  real deploy derives them from an authenticated session (see docs/driftwood-dogfood.md).
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {DriftwoodWeb.Layouts, :root})
    plug(:protect_from_forgery)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", DriftwoodWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
    get("/healthz", PageController, :healthz)

    live("/broker", BrokerLive)
    live("/operator/impersonate", OperatorImpersonationLive)
    live("/operator/aggregate", OperatorDashboardLive)
  end
end
