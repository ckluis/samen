defmodule DemoWeb.Router do
  @moduledoc """
  The demo host's top-level Plug router. It mounts the public API under the versioned
  URL namespace `/api/v1` (T3.11; doc §external-surface "explicitly versioned,
  URL-namespaced, e.g. /api/v1").

  `forward "/api/v1", …` strips the `/api/v1` prefix before the AshJsonApi router
  sees the request, so the router's declared routes (`/contacts`, `/users`, …) are
  reached at `/api/v1/contacts`, `/api/v1/users`, … externally — the stable public
  contract a tenant integrates against.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/api/v1", to: DemoWeb.Api.Endpoint)

  match _ do
    send_resp(conn, 404, "not found")
  end
end
