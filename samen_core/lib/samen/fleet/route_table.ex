defmodule Samen.Fleet.RouteTable do
  @moduledoc """
  The CLOSED fleet route surface (ADR-044 §4.4a "the complete route surface" +
  §5.3's tier-2 deep-link resolve routes) — declared once, as DATA, so `mix
  samen.verify.fleet_wire`'s RP-J-4b cross-check has a table to compare a real
  router against rather than a hand-maintained assertion that drifts.

  `verb`/`path` mirror Phoenix's own `%Phoenix.Router.Route{}` shape closely
  enough to compare directly (`router.__routes__/0` entries carry `.verb` and
  `.path`).
  """

  @typedoc "One declared fleet route."
  @type route :: %{verb: atom(), path: String.t(), side: atom(), note: String.t()}

  @doc """
  The closed route surface this task actually builds (§4.4a + §5.3's resolve
  routes) — `mix samen.verify.fleet_wire`'s RP-J-4b cross-check target.

  `GET /fleet/apps` (§4.4a's "operator-session JSON read API for the cockpit's
  own UI + scripts/") is DEFERRED, not declared here — see `deferred/0`. It
  needs its OWN self-contained operator-session authenticator (it is
  explicitly NOT part of any `live_session`, so it cannot reuse the Mount the
  LiveView routes carry — the ADR's own `Samen.Web.MetricsController`-shaped
  comparison names exactly this: self-gating, not live-session-gating). Ruling
  R-B/M10-class rigor demands that authenticator be real and tested, not a
  stub; building it is a clean, separable follow-up rather than a rushed half
  gate under this task's scope.
  """
  @spec declared() :: [route()]
  def declared do
    [
      %{verb: :get, path: "/fleet/health", side: :app, note: "the health probe, mode A/B (§4.7)"},
      %{verb: :post, path: "/fleet/directive", side: :app, note: "cockpit→app directive push (§7.1)"},
      %{verb: :post, path: "/fleet/enroll", side: :cockpit, note: "single-use enrollment token (§4.3)"},
      %{verb: :post, path: "/fleet/heartbeat", side: :cockpit, note: "204 empty-always (§4.6)"},
      %{verb: :get, path: "/operator/fleet", side: :cockpit, note: "tier-1 cockpit (§5.4)"},
      %{verb: :get, path: "/operator/fleet/directives", side: :cockpit, note: "J4 publish UI (§7)"},
      %{verb: :get, path: "/operator/fleet/register", side: :cockpit, note: "J1 register/enroll UI (§4.2/§4.3)"},
      %{verb: :get, path: "/operator/fleet/:app_id", side: :cockpit, note: "tier-2 detail (§5.3/§5.4)"},
      %{
        verb: :get,
        path: "/operator/deliverability/resolve",
        side: :cockpit,
        note: "tier-2 deep-link handle→org resolve (§5.3) — deliverability"
      },
      %{
        verb: :get,
        path: "/operator/automation/resolve",
        side: :cockpit,
        note: "tier-2 deep-link handle→org resolve (§5.3) — automation"
      },
      %{
        verb: :get,
        path: "/operator/activity/resolve",
        side: :cockpit,
        note: "tier-2 deep-link handle→org resolve (§5.3) — activity"
      }
    ]
  end

  @doc "Routes named in the ADR but deliberately NOT built by this task — see `declared/0`'s note."
  @spec deferred() :: [route()]
  def deferred do
    [
      %{
        verb: :get,
        path: "/fleet/apps",
        side: :cockpit,
        note: "needs its OWN self-contained operator-session authenticator (not live_session-backed) — deferred, T84b"
      }
    ]
  end
end
