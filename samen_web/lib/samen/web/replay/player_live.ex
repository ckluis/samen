defmodule Samen.Web.Replay.PlayerLive do
  @moduledoc """
  The replay PLAYER (ADR-052 §2.3) — `/operator/replays/:org_id/:id` (operator plane) and
  `/settings/replays/:id` (tenant plane). A replay is impersonation pointed at the past.

  ## Open (connected mount only — exactly one audit row per open)

  The dead render shows a shell and reads nothing. On the CONNECTED mount the player:

    1. authorizes the viewer (`Samen.Web.Replay.Access`): an operator needs an ACTIVE
       impersonation session for the replay's org; a tenant viewer needs an admin-class role in
       the SAME org. Refused → the refusal card; nothing read, nothing written;
    2. loads the session + frames under the viewer's scope (`Samen.Replay.Player.load/2`) —
       decoded references, never values; another org's replay is not found;
    3. writes ONE token-only `aud_event` (`replay.viewed`, `Samen.Replay.Player.audit_viewed/2`).
       If that write fails the player fails CLOSED: nothing is shown.

  ## Every frame batch re-authorizes (deny-on-read)

  Each step, scrub, seek and play tick shows one frame — a batch — and starts by calling
  `Access.authorize/3` again. An impersonation session that expired, closed or was suspended,
  or a tenant role that was lowered, STOPS playback: the frames and the rendered frame are
  dropped from the socket and nothing more renders. Then `Samen.Replay.Resolver` resolves the
  frame's references NOW, on the viewer's plane (a reveal grant that lapsed takes effect on the
  next batch), and `Samen.Web.Replay.Renderer` renders the recorded view's CURRENT `render/1`
  into an inert document shown in `<iframe sandbox="">`. Handlers never run; nothing is
  re-driven. Resolved values are labelled CURRENT. Only the frame on screen is held.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Replay.Live

  alias Samen.Replay.Player
  alias Samen.Web.Replay.{Access, Renderer}

  @tick_ms 900

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> viewer_context(params, session)
      |> assign(
        replay_id: params["id"],
        state: :connecting,
        deny_reason: nil,
        open_error: nil,
        playing?: false
      )
      |> clear()

    if connected?(socket), do: {:ok, open(socket)}, else: {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("step", %{"dir" => dir}, socket) do
    delta = if dir == "prev", do: -1, else: 1
    {:noreply, socket |> assign(playing?: false) |> show(socket.assigns.index + delta)}
  end

  def handle_event("seek", %{"frame" => frame}, socket) do
    case Integer.parse(to_string(frame)) do
      {i, ""} -> {:noreply, socket |> assign(playing?: false) |> show(i)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("play", _params, socket) do
    if socket.assigns.state == :open do
      Process.send_after(self(), :tick, @tick_ms)
      {:noreply, assign(socket, playing?: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("pause", _params, socket), do: {:noreply, assign(socket, playing?: false)}

  def handle_event("open_session", %{"reason" => reason}, socket) do
    case open_session(socket, reason) do
      :ok -> {:noreply, socket |> assign(open_error: nil) |> open()}
      {:error, copy} -> {:noreply, assign(socket, open_error: copy)}
    end
  end

  @impl true
  def handle_info(:tick, %{assigns: %{playing?: true, state: :open}} = socket) do
    last = length(socket.assigns.frames) - 1

    if socket.assigns.index >= last do
      {:noreply, assign(socket, playing?: false)}
    else
      socket = show(socket, socket.assigns.index + 1)
      if socket.assigns.playing?, do: Process.send_after(self(), :tick, @tick_ms)
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Open

  @doc false
  def open(socket) do
    %{org_id: org_id, user_id: user_id, replay_id: replay_id} = socket.assigns

    with {:auth, {:ok, viewer}} <- {:auth, Access.authorize(socket, org_id, user_id)},
         {:load, {:ok, %{session: session, frames: frames}}} <-
           {:load, Player.load(viewer.scope, to_string(replay_id))},
         {:audit, {:ok, _}} <- {:audit, Player.audit_viewed(audit_attrs(viewer, session))} do
      view = Player.view_module(session.view)

      socket
      |> assign(
        state: :open,
        deny_reason: nil,
        session: session,
        frames: frames,
        timeline: Player.timeline(frames),
        drift: Player.drift(session),
        view: view,
        view_mount: Renderer.view_mount(socket.router, view, route(frames), plane(viewer))
      )
      |> show(0)
    else
      {:auth, {:error, reason}} -> socket |> clear() |> assign(state: :denied, deny_reason: reason)
      {:load, _} -> socket |> clear() |> assign(state: :not_found)
      {:audit, _} -> socket |> clear() |> assign(state: :audit_failed)
    end
  end

  defp audit_attrs(viewer, session) do
    %{
      replay_id: session.id,
      org_id: viewer.org_id,
      viewer_id: viewer.viewer_id,
      plane: viewer.plane,
      impersonation_session_id: viewer.impersonation_session_id
    }
  end

  defp plane(%{plane: :operator, viewer_id: op, org_id: org, impersonation_session_id: sid}),
    do: {:operator, op, org, sid}

  defp plane(_viewer), do: :tenant

  defp route(frames) do
    Enum.find_value(frames, fn
      %{kind: :params, payload: %{route: route}} when is_binary(route) -> route
      _ -> nil
    end)
  end

  # ---------------------------------------------------------------------------
  # One frame batch: re-authorize, resolve NOW, render, hold only this frame.

  @doc false
  def show(%{assigns: %{state: :open}} = socket, index) do
    %{org_id: org_id, user_id: user_id, frames: frames} = socket.assigns
    index = index |> max(0) |> min(max(length(frames) - 1, 0))

    case Access.authorize(socket, org_id, user_id) do
      {:ok, viewer} ->
        %{value: resolved, refs: refs} = Player.resolve(Player.assigns_at(frames, index), viewer.scope)

        {html, error} =
          case Renderer.render(socket.assigns.view, context(resolved, socket.assigns)) do
            {:ok, html} -> {html, nil}
            {:error, reason} -> {nil, reason}
          end

        assign(socket,
          index: index,
          frame: Enum.at(frames, index),
          frame_html: html,
          frame_error: error,
          refs: refs
        )

      {:error, _reason} ->
        socket |> clear() |> assign(state: :stopped, deny_reason: :expired, playing?: false)
    end
  end

  def show(socket, _index), do: socket

  # The recorded assigns, plus the context the recorder never stores: the view's mount (code,
  # routed by the host) on the VIEWER's plane.
  defp context(resolved, assigns) do
    case assigns[:view_mount] do
      nil -> resolved
      mount -> Map.put(resolved, :samen_mount, mount)
    end
    |> Map.put_new(:samen_acting_as, false)
  end

  # Drop everything replay-derived from the socket (nothing more renders).
  defp clear(socket) do
    assign(socket,
      session: nil,
      frames: [],
      timeline: [],
      drift: nil,
      view: nil,
      view_mount: nil,
      index: 0,
      frame: nil,
      frame_html: nil,
      frame_error: nil,
      refs: []
    )
  end

  # ---------------------------------------------------------------------------
  # Render

  @impl true
  def render(assigns) do
    ~H"""
    <div id="replay-player" data-plane={if @operator?, do: "operator", else: "tenant"} data-state={@state}>
      <.replay_shell
        operator?={@operator?}
        mount={@samen_mount}
        org_id={@org_id}
        user_id={@user_id}
        title="Session replay"
        crumbs={[if(@operator?, do: "Operator plane", else: "Settings"), "Replays", (@session && @session.view_short) || "—"]}
      >
        <:actions>
          <a href={index_path(assigns)} id="back-to-replays" class="btn">← Replays</a>
        </:actions>

        <%= cond do %>
          <% @state in [:denied, :stopped] -> %>
            <.denied reason={@deny_reason} operator?={@operator?} open_error={@open_error} />
          <% @state == :connecting -> %>
            <div class="wrap"><div class="card" id="replay-connecting" style="padding:22px 20px;color:var(--muted)">Loading replay…</div></div>
          <% @state == :not_found -> %>
            <div class="wrap"><div class="card" id="replay-not-found" style="padding:22px 20px;color:var(--muted)">No such replay in this org.</div></div>
          <% @state == :audit_failed -> %>
            <div class="wrap"><div class="card" id="replay-audit-failed" style="padding:22px 20px;color:var(--red)">This replay could not be opened: the access could not be recorded.</div></div>
          <% true -> %>
            <div class="wrap replay-wrap">
              <.token_blind_bar chip="values are CURRENT · resolved on your plane now">
                <b>{@session.view_short}</b>
                recorded {fmt(@session.started_at)} · {length(@frames)} frames.
                Referenced fields show their <b>current</b> value (late binding), resolved for you
                now — not the value at recording time. Typed input is shape only.
              </.token_blind_bar>

              <div id="replay-drift" class="replay-meta">
                <.pill variant={drift_variant(@drift)}>{drift_label(@drift)}</.pill>
                <span :if={@playing?} id="replay-playing" class="pill info"><span class="d"></span>playing</span>
              </div>

              <div id="replay-controls" class="replay-controls">
                <button type="button" class="btn" id="replay-prev" phx-click="step" phx-value-dir="prev" disabled={@index == 0}>← Prev</button>
                <%= if @playing? do %>
                  <button type="button" class="btn" id="replay-pause" phx-click="pause">Pause</button>
                <% else %>
                  <button type="button" class="btn primary" id="replay-play" phx-click="play">Play</button>
                <% end %>
                <button type="button" class="btn" id="replay-next" phx-click="step" phx-value-dir="next" disabled={@index >= length(@frames) - 1}>Next →</button>
                <form phx-change="seek" id="replay-scrub-form" class="replay-scrub">
                  <label for="replay-scrub">Frame {@index + 1} / {length(@frames)}</label>
                  <input type="range" id="replay-scrub" name="frame" min="0" max={max(length(@frames) - 1, 0)} value={@index} />
                </form>
              </div>

              <div class="replay-stage">
                <div class="replay-screen">
                  <div class="replay-frame-head">
                    <span class="mono" id="replay-frame-label">{@frame && Player.label(@frame)}</span>
                    <span class="lane">at {(@frame && @frame.at_ms) || 0} ms</span>
                  </div>
                  <iframe
                    :if={@frame_html}
                    id="replay-frame"
                    title="Recorded frame (inert)"
                    sandbox=""
                    referrerpolicy="no-referrer"
                    loading="lazy"
                    srcdoc={@frame_html}
                    class="replay-iframe"
                  ></iframe>
                  <div :if={is_nil(@frame_html)} id="replay-frame-placeholder" class="card replay-placeholder">
                    {frame_error_copy(@frame_error, @view)}
                  </div>
                </div>

                <aside class="replay-side">
                  <div class="gtitle"><h3>This frame</h3></div>
                  <.data_table :if={Player.shape_rows(@frame || %{}) != []}>
                    <:head><th>Param</th><th>Type</th><th>Len</th><th>Shape</th><th>Kept value</th></:head>
                    <tr :for={row <- Player.shape_rows(@frame)} class="shape-row">
                      <td class="mono">{row.key || "—"}</td>
                      <td>{row.type}</td>
                      <td>{row.length || "—"}</td>
                      <td>{row.class}</td>
                      <td class="mono">{row.value || "—"}</td>
                    </tr>
                  </.data_table>

                  <div class="gtitle" style="margin-top:14px"><h3>References</h3><span class="n">{length(@refs)}</span><span class="lane">· current values</span></div>
                  <.data_table :if={@refs != []}>
                    <:head><th>Field</th><th>Current value</th></:head>
                    <tr :for={r <- @refs} class="ref-row" data-outcome={r.outcome}>
                      <td class="mono">{r.resource}.{r.attribute}</td>
                      <td><.pill variant={outcome_variant(r.outcome)}>{outcome_label(r.outcome)}</.pill></td>
                    </tr>
                  </.data_table>
                  <p :if={@refs == []} class="lane" id="replay-no-refs">No referenced personal data in this frame.</p>
                </aside>
              </div>

              <div id="replay-timeline" class="replay-timeline">
                <div class="gtitle"><h3>Timeline</h3></div>
                <ol>
                  <%= for e <- @timeline do %>
                    <%= if e.type == :gap do %>
                      <li class="tl-gap" data-gap={e.reason}>{gap_copy(e)}</li>
                    <% else %>
                      <li class={["tl-frame", e.index == @index && "on"]}>
                        <button type="button" phx-click="seek" phx-value-frame={e.index} class="tl-btn" id={"tl-#{e.index}"}>
                          <span class="mono">{e.at_ms} ms</span> {e.label}
                        </button>
                      </li>
                    <% end %>
                  <% end %>
                </ol>
              </div>
            </div>
        <% end %>
      </.replay_shell>
      <style>
        .replay-meta{display:flex;gap:8px;align-items:center;margin:10px 0}
        .replay-controls{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:8px 0 12px}
        .replay-scrub{display:flex;gap:8px;align-items:center;flex:1 1 220px;font-size:12px;color:var(--muted)}
        .replay-scrub input{flex:1;min-width:120px}
        .replay-stage{display:grid;grid-template-columns:minmax(0,1fr) 320px;gap:14px}
        .replay-frame-head{display:flex;justify-content:space-between;font-size:12px;margin-bottom:6px}
        .replay-iframe{width:100%;height:68vh;border:1px solid #E4E7EC;border-radius:10px;background:#fff}
        .replay-placeholder{padding:22px 20px;color:var(--muted)}
        .replay-timeline ol{list-style:none;margin:0;padding:0;max-height:260px;overflow:auto}
        .replay-timeline li{font-size:12px;padding:2px 0}
        .replay-timeline .tl-gap{color:var(--muted);font-style:italic}
        .replay-timeline .on .tl-btn{font-weight:700}
        .tl-btn{background:none;border:0;padding:0;cursor:pointer;text-align:left;color:inherit}
        .replay-open-form{display:flex;flex-wrap:wrap;gap:8px}
        .replay-open-form input{flex:1 1 220px;padding:8px 10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px}
        @media (max-width: 900px){.replay-stage{grid-template-columns:1fr}.replay-iframe{height:56vh}}
      </style>
    </div>
    """
  end

  defp fmt(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S")
  defp fmt(_), do: "—"

  defp drift_variant(:same), do: "ok"
  defp drift_variant(:changed), do: "warn"
  defp drift_variant(_), do: "bad"

  defp drift_label(:same), do: "code unchanged since recording"
  defp drift_label(:changed), do: "code changed since recording — frames render with today's view"
  defp drift_label(_), do: "the recorded view no longer exists"

  defp outcome_variant(:clear), do: "ok"
  defp outcome_variant(:masked), do: "mut"
  defp outcome_variant(:shredded), do: "bad"
  defp outcome_variant(_), do: "warn"

  defp outcome_label(:clear), do: "shown (current)"
  defp outcome_label(:masked), do: "•••• masked"
  defp outcome_label(:shredded), do: "erased (shredded)"
  defp outcome_label(:gone), do: "gone"
  defp outcome_label(:empty), do: "empty"
  defp outcome_label(_), do: "code changed"

  defp frame_error_copy(_error, nil), do: "The recorded view no longer exists in this release."

  defp frame_error_copy(:render_failed, _view),
    do: "This frame cannot be rendered by today's view (a placeholder or changed code)."

  defp frame_error_copy(_error, _view), do: "No frame to show."

  defp gap_copy(%{reason: :missing_frames, n: n}), do: "— #{n} frame(s) not stored —"
  defp gap_copy(%{reason: :idle, n: n}), do: "— #{n}s idle —"
  defp gap_copy(_), do: "— gap —"
end
