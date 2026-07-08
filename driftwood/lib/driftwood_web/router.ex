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

  # F1 (Gate-5 carry) — the versioned public API surface. `forward` sends `/api/v1/*` to
  # the AshJsonApi endpoint (key-auth → the two key classes → the generated JSON:API
  # router over `Driftwood.Freight`). The declared route `/drivers` is reached at
  # `/api/v1/drivers` externally — the stable public contract (doc §external-surface
  # "explicitly versioned, URL-namespaced, e.g. /api/v1").
  forward("/api/v1", DriftwoodWeb.Api.Endpoint)

  scope "/", DriftwoodWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
    get("/healthz", PageController, :healthz)

    live("/broker", BrokerLive)
    live("/operator/impersonate", OperatorImpersonationLive)
    live("/operator/aggregate", OperatorDashboardLive)

    # ADR-008: the Samen UI kit preview — a living catalog exercising every
    # DriftwoodWeb.UIKit component (app shell, sidebar, topbar, button, tabs, data
    # table, pill, progress, metric, mask-bar, token-blind bar), including masked
    # cells that render `••••` through Phoenix.HTML.Safe (no reveal path on the page).
    live("/ui-kit", UIKitLive)
  end
end
