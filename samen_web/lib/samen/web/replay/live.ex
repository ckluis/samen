defmodule Samen.Web.Replay.Live do
  @moduledoc """
  Shared chrome + plumbing for the two replay LiveViews (`Samen.Web.Replay.IndexLive`,
  `Samen.Web.Replay.PlayerLive`; ADR-052 §2.3), which run on BOTH planes:

    * the operator plane — `/operator/replays/:org_id[/:id]` in `samen_operator_routes/2`
      (operator sidebar; the per-tenant impersonation gate);
    * the tenant plane — `/settings/replays[/:id]` in `samen_settings_routes/3` (settings
      sidebar; an admin-class member of the same org).

  `viewer_context/3` resolves who is asking (never deciding — `Samen.Web.Replay.Access` decides);
  `denied/1` renders a refusal with NOTHING of the replay in it (operator: the
  open-session-with-reason form, the `Samen.Web.Operator.ActivityLive` affordance).
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.Operator.Live, only: [operator_sidebar: 1]
  import Samen.Web.Settings.Live, only: [settings_sidebar: 1]

  alias Samen.Web.{CurrentOrg, Mount}
  alias Samen.Web.Operator.Impersonation
  alias Samen.Web.Replay.{Access, Recorder}
  alias Samen.Web.Settings.Reads

  @doc """
  Mount plumbing shared by both LiveViews: the mount, the recorder opted OUT (a player is never
  itself recorded), and the asking viewer's identity: `operator?`, `org_id`, `user_id`.
  """
  @spec viewer_context(Phoenix.LiveView.Socket.t(), map(), map()) :: Phoenix.LiveView.Socket.t()
  def viewer_context(socket, params, session) do
    socket = socket |> Samen.Web.Live.assign_mount(session) |> Recorder.opt_out()
    mount = socket.assigns[:samen_mount]

    if Access.operator_mount?(mount) do
      socket
      |> Impersonation.assign_identity(session, params)
      |> assign(operator?: true, org_id: present(params["org_id"]), user_id: nil)
    else
      assign(socket,
        operator?: false,
        org_id: CurrentOrg.resolve(mount, params, session),
        user_id: Reads.current_user_id(mount, params, session)
      )
    end
  end

  @doc "The path of the replay list for this viewer (operator or settings route)."
  @spec index_path(map()) :: String.t()
  def index_path(%{operator?: true, org_id: org}), do: "/operator/replays/#{org}"
  def index_path(%{samen_mount: mount, org_id: org}), do: settings_path(mount, "/replays", org)

  @doc "The path of one replay for this viewer."
  @spec replay_path(map(), String.t()) :: String.t()
  def replay_path(%{operator?: true, org_id: org}, id), do: "/operator/replays/#{org}/#{id}"

  def replay_path(%{samen_mount: mount, org_id: org}, id),
    do: settings_path(mount, "/replays/#{id}", org)

  defp settings_path(mount, sub, org) do
    base = Mount.label(mount, :settings_path, "/settings")
    query = if is_binary(org), do: "?" <> URI.encode_query(org: org), else: ""
    base <> sub <> query
  end

  @doc "Open an impersonation session (the operator denied-state form) — `Impersonation.open_from_socket/3`."
  @spec open_session(Phoenix.LiveView.Socket.t(), String.t()) :: :ok | {:error, String.t()}
  def open_session(socket, reason) do
    case Impersonation.open_from_socket(socket, socket.assigns[:org_id], reason) do
      {:ok, _session} -> :ok
      {:error, :reason_required} -> {:error, "A reason for access is required."}
      {:error, :not_authorized} -> {:error, "Your operator role may not open an impersonation session."}
      {:error, {:pii_shaped_reason, _}} -> {:error, "The reason must name the ticket, not the person."}
      {:error, _} -> {:error, "The impersonation session could not be opened."}
    end
  end

  attr :operator?, :boolean, required: true
  attr :mount, :any, default: nil
  attr :org_id, :string, default: nil
  attr :user_id, :string, default: nil
  attr :title, :string, required: true
  attr :crumbs, :list, default: []
  slot :actions
  slot :inner_block, required: true

  @doc "The replay page shell on the viewer's plane."
  def replay_shell(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <%= if @operator? do %>
          <.operator_sidebar mount={@mount} active={:replays} />
        <% else %>
          <.settings_sidebar mount={@mount} org_id={@org_id} user_id={@user_id} active={:replays} />
        <% end %>
      </:sidebar>
      <.topbar title={@title} crumbs={@crumbs}>
        <:actions>{render_slot(@actions)}</:actions>
      </.topbar>
      {render_slot(@inner_block)}
    </.app_shell>
    """
  end

  attr :reason, :atom, required: true
  attr :operator?, :boolean, required: true
  attr :open_error, :string, default: nil

  @doc "The refusal card. Renders nothing of any replay."
  def denied(assigns) do
    ~H"""
    <div class="wrap">
      <div class="card" id="replay-denied" data-reason={@reason} style="padding:22px 20px">
        <div style="color:var(--red);font-weight:600" id="replay-denied-title">{denied_title(@reason)}</div>
        <p style="color:var(--muted);margin:10px 0 14px;font-size:13px">{denied_body(@reason)}</p>
        <%= if @operator? and @reason == :no_session do %>
          <div :if={@open_error} id="open-error" style="color:#B42318;font-size:12px;margin-bottom:8px">
            {@open_error}
          </div>
          <form phx-submit="open_session" id="open-session-form" class="replay-open-form">
            <input
              type="text"
              name="reason"
              id="session-reason-input"
              placeholder="Reason (e.g. ticket #1234: replay the failed save)"
              aria-label="Reason for access"
            />
            <button type="submit" id="start-session-btn" class="btn primary">Start session</button>
          </form>
        <% end %>
      </div>
    </div>
    """
  end

  defp denied_title(:no_session), do: "Access denied — no active impersonation session for this tenant."
  defp denied_title(:out_of_scope), do: "This account is not in your scope."
  defp denied_title(:not_admin), do: "Replays are visible to org admins only."
  defp denied_title(:cross_org), do: "Replays are visible only within your own org."
  defp denied_title(:operator_plane), do: "Operators watch replays from the operator console."
  defp denied_title(:expired), do: "Playback stopped — access ended."
  defp denied_title(_), do: "No org resolved."

  defp denied_body(:no_session),
    do:
      "Watching a replay is impersonating: it requires a short-TTL, reason-required " <>
        "impersonation session for this org, recorded in the tenant's ledger. Referenced " <>
        "personal data still shows •••• unless a separate reveal grant covers the subject."

  defp denied_body(:out_of_scope),
    do: "Your operator assignment does not cover this tenant; no session can be opened for it."

  defp denied_body(:not_admin),
    do: "A session replay shows what a member did. Only an owner or admin of this org may watch one."

  defp denied_body(:cross_org), do: "A replay is never shown across an org boundary."

  defp denied_body(:operator_plane),
    do: "Open the tenant from the operator console and start an impersonation session there."

  defp denied_body(:expired),
    do: "The session or role that allowed this replay is no longer active. Nothing more is shown."

  defp denied_body(_), do: "Pick an org to see its replays."

  defp present(v) when is_binary(v) and v != "", do: v
  defp present(_), do: nil
end
