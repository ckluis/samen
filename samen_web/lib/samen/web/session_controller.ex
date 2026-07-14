defmodule Samen.Web.SessionController do
  @moduledoc """
  The framework endpoint that WRITES the session current org (ADR-013 §4.3).

  A LiveView cannot set a cookie mid-mount — the session is established on the dead render —
  so the ONE state-changing nav (choose the current org) goes through a plain Phoenix
  controller so the cookie is set on a real HTTP response. This mirrors the ADR-010 rule of
  thumb: reads happen in LiveViews; the durable current-org write happens here.

  `put_current_org/2` — `GET /session/org/:org_id` — sets
  `session["samen_current_org"] = org_id` and redirects to `return_to` (default
  `/crm/contacts`). This is the target of BOTH the workspace switcher (§5.1) and the operator
  "Open account →" clear act-as drill-in (§5.2). Mounted via the one-line host helper
  `samen_session_routes()` (`Samen.Web.Router`), so every vertical inherits it.

  ## `return_to` is same-origin only (no open redirect)

  `return_to` is sanitized to a same-origin ABSOLUTE PATH (must start with `/` and not `//`).
  A missing/foreign value falls back to `/crm/contacts`. So a crafted `?return_to=https://evil`
  can never bounce a viewer off-site.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Web.CurrentOrg

  @default_return "/crm/contacts"

  @doc "Set the session current org to `:org_id` and redirect to a sanitized `return_to`."
  def put_current_org(conn, %{"org_id" => org_id} = params) do
    # WS-B / G12 (design §4.2): the framework session choke point emits a bounded,
    # token-blind `session.signed_in` product event — best-effort (a capture failure
    # never affects the session write). Verticals inherit emission at 0 LOC.
    _ = Samen.Analytics.Sources.session_signed_in(org_id)

    conn
    |> put_session(CurrentOrg.session_key(), org_id)
    |> redirect(to: safe_return(params["return_to"]))
  end

  # Only a same-origin absolute path (starts with a single "/") is honored; anything else
  # (a scheme-relative "//host", an absolute URL, a blank) falls back to the default.
  defp safe_return("/" <> rest = path) when rest != "" do
    if String.starts_with?(path, "//"), do: @default_return, else: path
  end

  defp safe_return(_), do: @default_return
end
