defmodule Samen.Web.Replay.Renderer do
  @moduledoc """
  Renders ONE replay frame to an inert, self-contained HTML document (ADR-052 §2.3 rule 3).

  The player never mounts the recorded LiveView and never runs a handler: it calls the
  recorded view's CURRENT `render/1` on the rebuilt, viewer-resolved assigns
  (`Samen.Replay.Resolver`), turns the result into a string server-side, and the player shows
  that string in `<iframe srcdoc sandbox="">` — no scripts, no forms, no same-origin, no
  LiveSocket. Nothing can be re-driven:

    * the string is built here, in the player's process, with `Phoenix.HTML.Safe` — no socket,
      no `handle_event`, no `handle_info`, no `mount`;
    * every `phx-*` binding attribute and every inline `on*` handler is stripped, and every
      `<script>` element removed, before the document is assembled;
    * the document carries a Content-Security-Policy that forbids scripts, connections,
      frames and form submission (`default-src 'none'`), and the player's iframe is
      `sandbox=""` (no `allow-scripts`) — two independent locks over the same door;
    * the template runs in a throwaway process with a capped heap and a deadline
      (`budget/0`): stored rows are untrusted, and no row can make a render unbounded.

  A template that raises (a placeholder where it expected a struct, a renamed assign, code
  that changed since the recording) returns `{:error, :render_failed}`; the player shows a
  placeholder for that frame and carries on. The exception is never rendered or logged with
  its message (a message can carry a value).

  `view_mount/4` finds the `Samen.Web.Mount` the recorded view is routed with in the HOST
  router (the recorder drops the mount — it is not data), rebuilt on the VIEWER's plane.
  """

  alias Samen.Web.Mount

  @css_path Path.join([__DIR__, "..", "..", "..", "..", "priv", "static", "assets", "samen_ui.css"])
            |> Path.expand()
  @external_resource @css_path
  @css (case File.read(@css_path) do
          {:ok, css} -> css
          _ -> ""
        end)

  # 8M words = 64 MiB on a 64-bit VM; a real frame (a 50-row list with the inlined kit
  # stylesheet) needs well under 1 MiB.
  @max_heap_words 8_000_000
  @render_timeout_ms 3_000

  @csp "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; " <>
         "form-action 'none'; frame-src 'none'; base-uri 'none'"

  @doc "The Content-Security-Policy every rendered frame document carries."
  @spec csp() :: String.t()
  def csp, do: @csp

  @doc """
  Render `view`'s CURRENT `render/1` with `assigns` (already resolved for the viewer) and
  return `{:ok, document}` — a complete, inert HTML document for `srcdoc` — or
  `{:error, :no_view | :render_failed}`.
  """
  @spec render(module() | nil, map()) :: {:ok, String.t()} | {:error, :no_view | :render_failed}
  def render(nil, _assigns), do: {:error, :no_view}

  def render(view, assigns) when is_atom(view) and is_map(assigns) do
    if function_exported?(view, :render, 1),
      do: bounded(fn -> render_body(view, assigns) end),
      else: {:error, :no_view}
  end

  defp render_body(view, assigns) do
    body =
      assigns
      |> Map.put(:__changed__, nil)
      |> Map.put_new(:flash, %{})
      |> view.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    {:ok, document(inert(body))}
  rescue
    _ -> {:error, :render_failed}
  catch
    _kind, _reason -> {:error, :render_failed}
  end

  @doc """
  The render's budget (ADR-052 P3 gate): the template runs in a throwaway process whose heap
  (shared binaries included) is capped and which is killed at the deadline. Stored rows are
  untrusted — an integer a template loops over (`1..@n`), a list or a nested term can make a
  tiny row render without bound — so a frame that exceeds the budget is `:render_failed`, never
  a player (or node) that runs out of memory. `$callers` is set so the render's reads see the
  same DB ownership as the player.
  """
  @spec budget() :: %{max_heap_words: pos_integer(), timeout_ms: pos_integer()}
  def budget, do: %{max_heap_words: @max_heap_words, timeout_ms: @render_timeout_ms}

  defp bounded(fun) do
    parent = self()
    callers = [parent | Process.get(:"$callers", [])]
    tag = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        Process.flag(:max_heap_size, %{
          size: @max_heap_words,
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        send(parent, {tag, fun.()})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, ^pid, _reason} ->
        {:error, :render_failed}
    after
      @render_timeout_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(mref, [:flush])

        receive do
          {^tag, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :render_failed}
    end
  end

  @doc """
  Strip everything that could act from rendered HTML: `<script>` elements, `<meta>` /
  `<base>` / `<link>` elements, `phx-*` binding attributes, inline `on*` event handlers and
  `javascript:` URLs.
  """
  @spec inert(String.t()) :: String.t()
  def inert(html) when is_binary(html) do
    html
    |> String.replace(~r/<script\b[^>]*>.*?<\/script\s*>/is, "")
    |> String.replace(~r/<script\b[^>]*\/?>/i, "")
    # Elements that act without a script and that neither the CSP nor the sandbox stops: a
    # `<meta http-equiv=refresh>` navigates the frame, `<base>` re-targets every link.
    |> String.replace(~r/<(?:meta|base|link)\b[^>]*>/i, "")
    # Inside TAGS only (Phoenix escapes `>` in attribute values, so a tag ends at its first `>`).
    |> then(&Regex.replace(~r/<[a-zA-Z][^>]*>/, &1, fn tag -> strip_attrs(tag) end))
    |> String.replace(~r/javascript\s*:/i, "about:blank#")
  end

  defp strip_attrs(tag) do
    Regex.replace(
      ~r/\s(?:phx-[a-z0-9_:.\-]+|on[a-z]+)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+))?/i,
      tag,
      ""
    )
  end

  @doc "Wrap a rendered body into the inert frame document (CSP + the kit stylesheet)."
  @spec document(String.t()) :: String.t()
  def document(body) do
    """
    <!doctype html><html><head><meta charset="utf-8">\
    <meta http-equiv="Content-Security-Policy" content="#{@csp}">\
    <meta name="referrer" content="no-referrer">\
    <style>#{@css}</style></head><body>#{body}</body></html>\
    """
  end

  @doc """
  The mount the recorded `view` is routed with in `router` (preferring the route whose path is
  the recorded route template), rebuilt on the viewer's plane: `plane` is `:tenant`, or
  `{:operator, operator_id, org_id, session_id}`. `nil` when the host routes no such view.
  """
  @spec view_mount(module() | nil, module() | nil, String.t() | nil, term()) :: Mount.t() | nil
  def view_mount(router, view, route, plane) when is_atom(router) and is_atom(view) do
    candidates =
      for %{path: path, metadata: %{phoenix_live_view: {^view, _action, _opts, live_session}}} <-
            Phoenix.Router.routes(router),
          raw = session_mount(live_session),
          is_map(raw),
          do: {path, raw}

    case Enum.find(candidates, fn {path, _} -> path == route end) || List.first(candidates) do
      {_path, raw} -> raw |> Mount.from_session() |> on_plane(plane)
      nil -> nil
    end
  rescue
    _ -> nil
  end

  def view_mount(_router, _view, _route, _plane), do: nil

  defp session_mount(%{extra: %{session: %{"samen_mount" => raw}}}), do: raw
  defp session_mount(_), do: nil

  defp on_plane(%Mount{} = mount, {:operator, operator_id, org_id, session_id}),
    do: %{mount | plane: Samen.Web.Plane.operator(operator_id, org_id, session_id)}

  defp on_plane(%Mount{} = mount, _tenant), do: %{mount | plane: Samen.Web.Plane.tenant()}
end
