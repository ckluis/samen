defmodule Samen.Web.Replay.IndexLive do
  @moduledoc """
  The replay LIST (ADR-052 §2.3) — `/operator/replays/:org_id` (operator plane, under an
  active impersonation session for the org) and `/settings/replays` (tenant plane, org
  admins). Authorized exactly like opening one (`Samen.Web.Replay.Access`), re-checked on
  every load; refused → nothing listed, nothing read.

  Lists BOUNDED METADATA only (`Samen.Replay.Player.list/2`, newest #{50}): the view module's
  name, when, how long, frame / interaction counts, the exit enum, truncation and the
  code-drift marker. No frame is read and no reference is resolved here, and listing writes no
  audit row — opening a replay does (`Samen.Web.Replay.PlayerLive`).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Replay.Live

  alias Samen.Replay.Player
  alias Samen.Web.Replay.Access

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> viewer_context(params, session)
      |> assign(open_error: nil)

    {:ok, load(socket)}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_session", %{"reason" => reason}, socket) do
    case open_session(socket, reason) do
      :ok -> {:noreply, load(socket)}
      {:error, copy} -> {:noreply, assign(socket, open_error: copy)}
    end
  end

  @doc false
  def load(socket) do
    case Access.authorize(socket, socket.assigns[:org_id], socket.assigns[:user_id]) do
      {:ok, viewer} ->
        sessions =
          viewer.scope
          |> Player.list()
          |> Enum.map(&Map.put(&1, :drift, Player.drift(&1)))

        assign(socket, state: :open, sessions: sessions, deny_reason: nil)

      {:error, reason} ->
        assign(socket, state: :denied, sessions: [], deny_reason: reason)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="replay-index" data-plane={if @operator?, do: "operator", else: "tenant"}>
      <.replay_shell
        operator?={@operator?}
        mount={@samen_mount}
        org_id={@org_id}
        user_id={@user_id}
        title="Session replays"
        crumbs={[if(@operator?, do: "Operator plane", else: "Settings"), "Replays", @org_id || "—"]}
      >
        <%= if @state == :denied do %>
          <.denied reason={@deny_reason} operator?={@operator?} open_error={@open_error} />
        <% else %>
          <div class="wrap">
            <.token_blind_bar chip="metadata only · values resolve when you open a replay">
              <b>Recorded sessions.</b>
              A replay stores references, never personal data. Opening one shows each referenced
              field as it is NOW, on your plane — and is recorded in this org's audit log.
            </.token_blind_bar>

            <.empty_state
              :if={@sessions == []}
              class="replays-empty"
              icon="▶"
              title="No recorded sessions."
              body="Session replay is off unless this org's samen.replay flag is on."
            />

            <.data_table :if={@sessions != []}>
              <:head>
                <th>View</th>
                <th>Started</th>
                <th>Frames</th>
                <th>Interactions</th>
                <th>Exit</th>
                <th>Code</th>
                <th></th>
              </:head>
              <tr :for={s <- @sessions} class="replay-row" id={"replay-#{s.id}"}>
                <td class="r-view mono">{s.view_short}</td>
                <td class="r-started">{fmt(s.started_at)}</td>
                <td class="r-frames">{s.frame_count}{if s.truncated, do: " (truncated)"}</td>
                <td class="r-interactions">{s.interaction_count}</td>
                <td class="r-exit">{s.exit_reason || "—"}</td>
                <td class="r-drift"><.pill variant={drift_variant(s.drift)}>{drift_label(s.drift)}</.pill></td>
                <td><a href={replay_path(assigns, s.id)} class="r-open" id={"open-#{s.id}"}>Open →</a></td>
              </tr>
            </.data_table>
          </div>
        <% end %>
      </.replay_shell>
    </div>
    """
  end

  defp fmt(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")
  defp fmt(_), do: "—"

  defp drift_variant(:same), do: "ok"
  defp drift_variant(:changed), do: "warn"
  defp drift_variant(_), do: "bad"

  defp drift_label(:same), do: "unchanged"
  defp drift_label(:changed), do: "changed since"
  defp drift_label(_), do: "view removed"
end
