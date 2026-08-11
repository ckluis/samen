defmodule Samen.Web.Work.TimelineLive do
  @moduledoc """
  Framework Work / Timeline page — Tasks positioned as horizontal BARS on a Gantt by their
  `:inserted_at`..`:due_at` range, grouped into STATUS lanes. The G3 TIMELINE view and the FIRST
  client of the generic `Samen.Web.Reads.timeline_window!/3` (T53/WS-G) rendered through
  `Samen.UI.gantt/1` — the horizontal counterpart of the CRM calendar (`Samen.Web.CRM.CalendarLive`).

  ## Framework-first (T53)

  This LiveView is THIN wiring over two framework primitives — it re-implements neither the
  window/overlap read nor the bar layout:

    * READ — `Samen.Web.Work.Reads.tasks_timeline/4` builds a lane-keyed `%Samen.Web.Board{}` via
      `timeline_window!/3`: Tasks WINDOWED to the displayed range (a DB-level start..end OVERLAP
      filter) and grouped by `:status` into ORDERED, per-lane-BOUNDED lanes, org-scoped by
      construction (unconditional OrgScope, inherited from `group_by!/3` — the T50 boundary).
    * RENDER — `Samen.UI.gantt/1` lays that `%Board{}` out as horizontal lanes with server-computed
      bar positions; this module supplies only the Work-specific `:bar` (task title/priority/due)
      and computes the window + prev/next navigation params. Any other domain reuses `gantt/1` with
      its own bar slot at ≈0 LOC.

  ## NULL due date (open-ended bar)

  A Task with no `:due_at` renders as a POINT marker at its `:inserted_at` — never an infinite bar
  (handled by `timeline_window!/3` treating a NULL end as a point).

  ## No-JS navigation floor (ADR-042/T113)

  Window navigation is `?from=YYYY-MM-DD` on this same route: prev/next render as real `<a href>`
  links, so a JS-off client shifts the window by ordinary GET (`handle_params/3` re-reads it). The
  lanes, every bar (with its computed position), the axis ticks, and each per-lane count are all
  server-rendered — the Gantt is not JS-only. A hostile/garbage `?from=` is parsed fail-safe to
  today, never a crash.

  ## Masking

  Tasks are NON-PII (no vault field on a bar) and the axis fields `:inserted_at`/`:due_at` are
  non-vaulted (`timeline_window!/3` would REFUSE a vaulted axis via
  `Samen.Web.Reads.MaskedGroupKeyError`), so no bar field masks and no per-plane masking proof is
  required for this surface. Reads still ride Ash/OrgScope.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Work.Live, only: [assign_mount: 2, work_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Board
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Work.Reads

  # The default window length in days (a 4-week lens). prev/next shift by this.
  @window_days 28
  @month_abbr ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    from = parse_from(Map.get(params, "from"), default_from())
    {:ok, load(assign(socket, org_id: org_id, from: from), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    from = parse_from(Map.get(params, "from"), socket.assigns[:from] || default_from())
    {:noreply, load(assign(socket, org_id: org_id, from: from, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, org_id, from \\ nil)

  def load(socket, nil, from) do
    from = from || socket.assigns[:from] || default_from()

    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      from: from,
      board: %Board{groups: [], group_field: :status},
      total_tasks: 0
    )
    |> assign_window(nil)
  end

  def load(socket, org_id, from) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)
    from = from || socket.assigns[:from] || default_from()
    range = window_range(from)

    %{board: board} = Reads.tasks_timeline(mount, scope, range)

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      from: from,
      board: board,
      total_tasks: total_tasks(board)
    )
    |> assign_window(org_id)
  end

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  # Compute the window range + the no-JS prev/next links (real `?org=&from=YYYY-MM-DD` GETs).
  defp assign_window(socket, org_id) do
    from = socket.assigns.from
    {range_start, range_end} = window_range(from)

    assign(socket,
      range_start: range_start,
      range_end: range_end,
      window_label: window_label(from),
      prev_href: from_href(org_id, Date.add(from, -@window_days)),
      next_href: from_href(org_id, Date.add(from, @window_days))
    )
  end

  # The window as a UTC DateTime range [midnight(from), midnight(from + window_days)).
  defp window_range(%Date{} = from) do
    {DateTime.new!(from, ~T[00:00:00], "Etc/UTC"),
     DateTime.new!(Date.add(from, @window_days), ~T[00:00:00], "Etc/UTC")}
  end

  # The window anchor defaults to a week before today (so recently-created tasks sit mid-window).
  defp default_from, do: Date.add(Date.utc_today(), -7)

  # Parse a `"YYYY-MM-DD"` `?from=` param to a Date, fail-safe to `default` (a hostile param
  # never crashes the mount — the no-JS nav param is bounded, not trusted).
  defp parse_from(value, %Date{} = default) do
    with str when is_binary(str) <- value,
         {:ok, date} <- Date.from_iso8601(String.trim(str)) do
      date
    else
      _ -> default
    end
  end

  defp from_href(org_id, %Date{} = from) do
    org = if org_id, do: "org=#{org_id}&", else: ""
    "?#{org}from=#{Date.to_iso8601(from)}"
  end

  defp window_label(%Date{} = from) do
    last = Date.add(from, @window_days - 1)
    "#{short(from)} – #{short(last)}, #{last.year}"
  end

  defp short(%Date{month: m, day: d}), do: "#{Enum.at(@month_abbr, m - 1)} #{d}"

  defp total_tasks(%Board{groups: groups}),
    do: Enum.reduce(groups, 0, fn g, acc -> acc + (g.count || length(g.rows)) end)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="work-timeline">
      <.app_shell>
        <:sidebar>
          <.work_sidebar mount={@samen_mount} org_id={@org_id} active={:work_timeline} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Timeline" crumbs={crumbs(@samen_mount, @org_id, "Timeline")} />

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Work org: {@org_id}</span>

          <div class="metrics">
            <.metric label="Tasks in window" value={@total_tasks} sub="by created → due">
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M3 6h18M3 12h12M3 18h7" />
                </svg>
              </:icon>
            </.metric>
          </div>

          <div class="wrap">
            <.gantt
              id="work-gantt"
              board={@board}
              range_start={@range_start}
              range_end={@range_end}
              start_field={:inserted_at}
              end_field={:due_at}
              window_label={@window_label}
              today={DateTime.utc_now()}
              prev_href={@prev_href}
              next_href={@next_href}
              empty_text="No tasks"
            >
              <:bar :let={task}>
                <span class="mono gantt-bar-name" id={"task-bar-#{task.id}"}>{task.title || "(untitled)"}</span>
                <.pill variant={priority_variant(task.priority)}>{priority_label(task.priority)}</.pill>
              </:bar>
            </.gantt>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id, leaf), do: [CurrentOrg.name(mount, org_id), "Work", leaf]

  defp priority_variant(:low), do: "mut"
  defp priority_variant(:normal), do: "info"
  defp priority_variant(:high), do: "warn"
  defp priority_variant(:urgent), do: "bad"
  defp priority_variant(_), do: "mut"

  defp priority_label(:low), do: "low"
  defp priority_label(:normal), do: "normal"
  defp priority_label(:high), do: "high"
  defp priority_label(:urgent), do: "urgent"
  defp priority_label(other), do: to_string(other)
end
