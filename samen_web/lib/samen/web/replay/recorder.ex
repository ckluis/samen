defmodule Samen.Web.Replay.Recorder do
  @moduledoc """
  The `Samen.Replay` recorder (ADR-052 §2.2, P2): lifecycle hooks on a CONNECTED tenant
  LiveView that write sanitized frames into the capture buffer.

  ## Adoption: 0 authored lines

  Every framework tenant `live_session` — and every host tenant session that reuses the gate
  (`driftwood`'s `:driftwood_broker`, `pawchart`'s `:pawchart_clinic`) — already carries
  `on_mount {Samen.Web.TenantAuthz, :require_tenant}`. `TenantAuthz` calls `attach/2` on its
  two TENANT legs (armed and disarmed) and never on its operator leg, so the operator plane
  cannot record. `on_mount(:record, …)` is the same hook for a host that wants it explicitly.

  ## What it captures

    * **mount** (once capture is decided ON): the sanitized assigns, the view module and its
      MD5, the `live_action`;
    * **handle_params**: the matched ROUTE TEMPLATE (`/crm/contacts/:id`, a developer literal —
      never the concrete path) and the params as SHAPE (`keep_url_params` keeps bounded values);
    * **after_render**: only the assigns in `__changed__`, sanitized;
    * **handle_info**: the message tag, only when it is a label-shaped atom;
    * **events**: recorded by `Samen.Replay.Capture` from LiveView's own `:start` telemetry.

  ## Off unless opted in, decided once

  The org is not known at `on_mount` on a disarmed host (it arrives as `:org_id` during
  `handle_params`), so the hooks start `:pending` and decide at the first callback that sees a
  UUID `:org_id` (or `:samen_tenant_org_id`): `Samen.Replay.decide/1` — the org's
  `samen.replay` flag AND the sample. `:off` (or no org after #{3} callbacks) DETACHES every
  hook, so an unrecorded LiveView pays nothing afterwards.

  ## Never crashes, never blocks

  Every hook body runs inside `rescue`/`catch`: a failure turns capture `:off` for that
  LiveView and returns the socket untouched. Frames are written to ETS from this process;
  persistence happens in the monitor's task after the LiveView exits.
  """

  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4, detach_hook: 3, put_private: 3]

  alias Samen.Replay.{Capture, Sanitizer}
  alias Samen.Web.Mount

  @private :samen_replay
  @max_pending 3
  @stages [:handle_params, :after_render, :handle_info]

  @doc "`on_mount {Samen.Web.Replay.Recorder, :record}` — attach on a tenant-plane mount."
  @spec on_mount(:record, map() | atom(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:record, _params, session, socket) do
    mount =
      case session do
        %{"samen_mount" => raw} when is_map(raw) -> Mount.from_session(raw)
        _ -> nil
      end

    {:cont, attach(socket, mount)}
  rescue
    _ -> {:cont, socket}
  end

  @doc """
  Attach the recorder hooks to `socket` when it is a CONNECTED, top-level LiveView on a TENANT
  plane mount and the capture plane is running. Otherwise the socket is returned unchanged.
  """
  @spec attach(Phoenix.LiveView.Socket.t(), Mount.t() | nil) :: Phoenix.LiveView.Socket.t()
  def attach(socket, mount) do
    if attachable?(socket, mount) do
      socket
      |> put_private(@private, %{state: :pending, tries: 0, keep: nil})
      |> attach_hook(@private, :after_render, &after_render/1)
      |> attach_hook(@private, :handle_info, &handle_info/2)
      |> maybe_attach_params()
    else
      socket
    end
  rescue
    _ -> socket
  end

  defp attachable?(socket, mount) do
    connected?(socket) and is_nil(socket.parent_pid) and tenant_plane?(mount) and
      not Map.has_key?(socket.private, @private) and Samen.Replay.running?()
  end

  # Fail-closed: only an explicit TENANT-plane mount records. No mount, an operator plane or an
  # operator/aggregate scope never does.
  defp tenant_plane?(%Mount{plane: %{kind: :tenant}, scope_kind: kind})
       when kind not in [:operator, :aggregate],
       do: true

  defp tenant_plane?(_), do: false

  # LiveViews rendered with live_render/3 are not mounted at the router: no handle_params hook.
  defp maybe_attach_params(%{router: nil} = socket), do: socket

  defp maybe_attach_params(socket),
    do: attach_hook(socket, @private, :handle_params, &handle_params/3)

  # ---------------------------------------------------------------------------
  # Hooks

  @doc false
  def handle_params(params, uri, socket) do
    {:cont,
     guarded(socket, fn s ->
       s = decide(s)
       if state(s) == :on, do: record_params(s, params, uri), else: s
     end)}
  end

  @doc false
  def after_render(socket) do
    guarded(socket, fn s ->
      case state(s) do
        :pending ->
          s = decide(s)
          # Opened by THIS render: the mount frame already carries every assign.
          s

        :on ->
          record_render(s)

        _ ->
          s
      end
    end)
  end

  @doc false
  def handle_info(message, socket) do
    {:cont,
     guarded(socket, fn s ->
       if state(s) == :on, do: record_info(s, message), else: s
     end)}
  end

  defp guarded(socket, fun) do
    fun.(socket)
  rescue
    _ -> off(socket)
  catch
    _, _ -> off(socket)
  end

  defp state(socket), do: get_in(socket.private, [@private, :state])

  # ---------------------------------------------------------------------------
  # Deciding + opening

  defp decide(socket) do
    priv = socket.private[@private]

    case priv do
      %{state: :pending} ->
        case org_id(socket.assigns) do
          nil -> pending(socket, priv)
          org -> open(socket, org)
        end

      _ ->
        socket
    end
  end

  defp pending(socket, %{tries: tries} = priv) do
    if tries + 1 >= @max_pending,
      do: off(socket),
      else: put_private(socket, @private, %{priv | tries: tries + 1})
  end

  defp open(socket, org) do
    with :on <- Samen.Replay.decide(org),
         {:ok, _id} <-
           Capture.open(%{
             org_id: org,
             view: socket.view,
             principal: socket.assigns[:samen_tenant_principal]
           }) do
      keep = Capture.keep(socket.view)
      socket = put_private(socket, @private, %{state: :on, tries: 0, keep: keep})
      record_mount(socket, keep)
      socket
    else
      _ -> off(socket)
    end
  end

  defp off(socket) do
    socket = put_private(socket, @private, %{state: :off, tries: 0, keep: nil})

    Enum.reduce(@stages, socket, fn stage, acc -> detach_hook(acc, @private, stage) end)
  rescue
    _ -> socket
  end

  defp org_id(assigns) do
    Enum.find_value([:org_id, :samen_tenant_org_id], fn key ->
      value = Map.get(assigns, key)
      if Sanitizer.uuid?(value), do: String.downcase(value)
    end)
  end

  # ---------------------------------------------------------------------------
  # Frames

  defp record_mount(socket, keep) do
    live_action = socket.assigns[:live_action]

    Capture.record(:mount, %{
      view: inspect(socket.view),
      view_md5: Capture.md5(socket.view),
      live_action: if(is_atom(live_action) and label_atom?(live_action), do: live_action),
      assigns: Sanitizer.assigns(socket.assigns, keep: keep.assigns)
    })
  end

  defp record_params(socket, params, uri) do
    keep = socket.private[@private].keep

    Capture.record(:params, %{
      route: route(socket, uri),
      params: Sanitizer.params(params, keep.url_params)
    })

    socket
  end

  defp record_render(%{assigns: %{__changed__: changed}} = socket)
       when is_map(changed) and map_size(changed) > 0 do
    if Capture.accepting?() do
      keep = socket.private[@private].keep

      Capture.record(:render, %{
        assigns: Sanitizer.assigns(socket.assigns, only: Map.keys(changed), keep: keep.assigns)
      })
    end

    socket
  end

  defp record_render(socket), do: socket

  defp record_info(socket, message) do
    case tag(message) do
      nil -> :ok
      tag -> Capture.record(:info, %{tag: tag})
    end

    socket
  end

  defp tag(message) when is_atom(message), do: if(label_atom?(message), do: message)

  defp tag(message)
       when is_tuple(message) and tuple_size(message) > 0 and is_atom(elem(message, 0)),
       do: tag(elem(message, 0))

  defp tag(_), do: nil

  defp label_atom?(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: Sanitizer.label?(Atom.to_string(atom))

  defp label_atom?(_), do: false

  # The ROUTE TEMPLATE the path matched (a developer literal), never the concrete path.
  defp route(%{router: router}, uri)
       when is_atom(router) and not is_nil(router) and is_binary(uri) do
    %URI{path: path, host: host} = URI.parse(uri)

    case Phoenix.Router.route_info(router, "GET", path || "/", host) do
      %{route: route} when is_binary(route) ->
        if Samen.Replay.FrameSchema.opaque_id?(route), do: route

      _ ->
        nil
    end
  end

  defp route(_socket, _uri), do: nil
end
