defmodule DriftwoodWeb.PageController do
  @moduledoc """
  The Driftwood landing + health endpoints.

  `/` routes a TENANT to their OWN workspace (`/broker?org=<their org>`); anyone else
  (an operator, or an anonymous visitor) still lands on the operator dashboard
  (`/operator/accounts`, ADR-013 §3 — zero params typed, sees all tenant accounts).

  PP-7 (Batch 3 NAV-REACHABILITY, W3 BLOCKER-1) — `/` used to redirect UNCONDITIONALLY to
  the operator console. A brand-new tenant who signed up, verified, and logged in (with no
  `return_to` — the ordinary case) landed on the SaaS's own cross-tenant Accounts console
  with no path into the product they just signed up for. The fix is a LANDING decision, not
  an authorization change: `tenant_landing/1` below asks "does this signed-in principal hold
  a REAL per-org Membership?" via the SAME framework Identity-spine seam
  `Samen.Web.CurrentOrg`/`Samen.Auth.OrgActor` already use to derive the tenant actor
  (`Samen.Web.Auth.resolve_principal/2` → `Samen.Auth.OrgActor.authorized_org_ids/2`) —
  never a fork, never a new auth mechanism. A genuine tenant (≥1 Membership row) is sent to
  `/broker`; everyone else (no session, or a session with no tenant Membership — the
  operator's own principal) falls through UNCHANGED to the existing operator landing. Every
  gate downstream (`Samen.Web.AuthGate`, `Samen.Web.Operator.Authz`,
  `Samen.Web.CurrentOrg.resolve/3`'s own fail-closed armed-host path) still runs exactly as
  before — this only decides WHERE a plain `GET /` sends the browser next.

  `/healthz` returns `ok` (the LIVENESS probe the boot check curls). `/readyz` is the
  READINESS probe (WS-F1 / F1.2) — 200 only when Postgres, the KMS wrapped-DEK store, and
  Oban all answer (`Samen.Web.Readiness`), else 503; the deploy traffic gate rides it.
  """
  use Phoenix.Controller, formats: [:html]

  import Plug.Conn

  alias Samen.Auth.OrgActor
  alias Samen.Web.Auth, as: WebAuth

  def index(conn, _params) do
    case tenant_landing(conn) do
      {:ok, path} -> redirect(conn, to: path)
      :none -> redirect(conn, to: "/operator/accounts")
    end
  end

  # A signed-in principal (the framework spine's `samen_session_token`, set only by a real
  # `POST /login` — never a query param) who holds a REAL `Identity.Membership` in at least
  # one org is a tenant; their landing is that org's freight console. Anything else (no
  # session, an unresolvable/expired token, or a resolved principal with NO Membership
  # anywhere — the operator's own principal never has one under this namespace) → `:none`,
  # preserving the pre-existing operator-console landing exactly. Never raises: an unreadable
  # session or a DB hiccup degrades to `:none`, the SAME safe fallback as no session at all.
  defp tenant_landing(conn) do
    conn = fetch_session(conn)
    session = get_session(conn)

    with {:ok, %{credential_id: credential_id}} <-
           WebAuth.resolve_principal(session, %{session: Driftwood.Operator.Session}),
         [org_id | _] <-
           OrgActor.authorized_org_ids(
             %{user: Driftwood.Operator.User, membership: Driftwood.Operator.Membership},
             credential_id
           ) do
      {:ok, "/broker?org=#{org_id}"}
    else
      _ -> :none
    end
  rescue
    _ -> :none
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
