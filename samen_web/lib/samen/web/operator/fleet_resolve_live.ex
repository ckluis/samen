defmodule Samen.Web.Operator.FleetResolveLive do
  @moduledoc """
  The ADR-044 §5.3 tier-2 deep-link RESOLVE step — `/operator/{deliverability,
  automation,activity}/resolve?fleet_handle=<32 hex>` (T84b). One shared module
  mounted three times (`live_action` distinguishes the target family, Phoenix's
  standard shared-LiveView-with-action pattern).

  ## Not a tier-3 promotion (§16.4a boundary, RP-J-11)

  This LiveView does ONE thing: maps a `fleet_handle` to an `org_id`
  (`Samen.Fleet.Resolution.resolve_org_id/2`) and REDIRECTS to the canonical
  `/operator/{family}/:org_id` route — where the FULL T146+scope+T150 gate
  (`Samen.Web.Operator.Impersonation.gate/3`, T84a-wired) runs exactly as it
  does for any other arrival. Resolution itself grants NOTHING:

    * it runs behind the SAME `:require_operator` `on_mount` every operator
      route inherits (this LiveView adds no separate gate — mounting inside
      `samen_operator_routes/2`'s `live_session` IS the T146 gate, RP-J-12);
    * an UNKNOWN handle (no seam, a non-matching handle, an erroring resolver)
      redirects to the product's platform index (`/operator/accounts`) with a
      flash — NEVER to a drill-in (fail-honest: resolution failure is not
      silently treated as "no tenant", it is a named, flashed dead end);
    * a KNOWN handle redirects to the canonical `:org_id` route, where access
      is decided FRESH — arriving via a resolve link confers no session,
      shortens no TTL, skips no reason, and requires no re-derivation of
      `org_id` on the far side (RP-J-11's "resolution must not precede the
      T146 gate" is satisfied by construction: T146 already ran, in THIS
      mount, before `handle_params/3` even fires).
  """
  use Phoenix.LiveView

  alias Samen.Fleet.Handle
  alias Samen.Web.Operator

  @family_path %{deliverability: "deliverability", automation: "automation", activity: "activity"}

  @impl true
  def mount(_params, session, socket) do
    {:ok, Samen.Web.Operator.Live.assign_mount(socket, session)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    otp_app = Operator.otp_app(socket.assigns[:samen_mount])
    handle = params["fleet_handle"]
    family = Map.get(@family_path, socket.assigns.live_action, "accounts")

    target =
      with true <- is_binary(handle) and Handle.well_formed?(handle),
           true <- is_atom(otp_app) and not is_nil(otp_app),
           {:ok, org_id} <- Samen.Fleet.Resolution.resolve_org_id(otp_app, handle) do
        {:known, "/operator/#{family}/#{org_id}"}
      else
        _ -> :unknown
      end

    case target do
      {:known, path} ->
        # Plain redirect/2 (never push_navigate/2): this LiveView is as often reached
        # by a FRESH/disconnected request (a bookmarked or copy-pasted resolve link) as
        # by a connected live-navigate, and push_navigate/2 raises on a disconnected
        # mount. redirect/2 works correctly in both states.
        {:noreply, redirect(socket, to: path)}

      :unknown ->
        {:noreply,
         socket
         |> put_flash(:error, "Unknown fleet handle — this tenant could not be resolved.")
         |> redirect(to: "/operator/accounts")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fleet-resolve"></div>
    """
  end
end
