defmodule Samen.UI.Calendar do
  @moduledoc """
  The GENERIC month-grid calendar — the framework renderer for a `%Samen.Web.Board{}` whose
  group KEYS are `Date`s (the value `Samen.Web.Reads.calendar_by_day!/3` returns). It lays the
  board's per-day columns out as a 6-week month grid: a weekday header row over `weeks × 7`
  day cells, each in-month cell showing its day number, an exact per-day COUNT, its
  per-day-BOUNDED events, and a `+N more` overflow when the day was capped.

  This is the calendar analogue of `Samen.UI.board/1`: `board/1` renders the same
  `%Board{}` as flat COLUMNS; `calendar/1` renders it positioned in a MONTH GRID. Both are
  framework-level and hold NO vertical logic — `calendar/1` is parameterized by the EVENT
  RENDERER (the required `:event` slot, `:let={row}`), so the CRM opportunity calendar (T52,
  first client), a tickets-by-due-date calendar, or a tasks calendar all reuse it at ≈0
  authored LOC. The vertical-specific part — which resource, which date field, which event
  fields — is thin wiring in the calling LiveView (`Samen.Web.CRM.CalendarLive`).

  ## Masking posture (dumb renderer, same as the rest of the kit)

  The calendar never inspects, coerces, or stringifies an event's field value: each event is
  whatever the `:event` slot renders from a row the CALLER already plane-resolved through
  `Samen.Api.PiiResolution` (exactly like `board/1`/`list_view/1`). If a row field is a
  `%Samen.Masked{}`, HEEx renders it `••••` through the shared `Phoenix.HTML.Safe` impl — the
  calendar has no "show plaintext" branch. The day KEY and COUNT are always a non-vaulted
  facet: `calendar_by_day!/3` (via `group_by!/3`) REFUSES a vault-routed date field
  (`Samen.Web.Reads.MaskedGroupKeyError`), so no plaintext or vault token can leak through a
  cell's position or count (INV-1).

  ## No-JS floor (progressive enhancement, ADR-042/T113)

  The grid, every day's events, and every per-day count are always in the server-rendered DOM
  — the calendar is NOT JS-only. Month navigation is a pair of real `<a href>` links carrying
  a `?month=YYYY-MM` param (`prev_href`/`next_href`), so a client with JS OFF navigates months
  by ordinary GET; the `+N more` overflow is legible server-rendered text (computed from the
  exact `count`), not a JS-only affordance.
  """
  use Phoenix.Component

  @weekdays_sun ~w(Sun Mon Tue Wed Thu Fri Sat)
  @weekdays_mon ~w(Mon Tue Wed Thu Fri Sat Sun)
  @month_names ~w(January February March April May June July August September October November December)

  @doc """
  Render a `%Samen.Web.Board{}` (day-keyed) as a month grid.

    * `:board` (required) — a `%Samen.Web.Board{}` whose group `key`s are `Date`s
      (`Samen.Web.Reads.calendar_by_day!/3` output).
    * `:month` (required) — any `Date` in the displayed month (normalized to the 1st).
    * `:id` — the DOM id of the calendar container (default `"calendar"`).
    * `:today` — the `Date` to highlight as "today" (default `Date.utc_today/0`).
    * `:prev_href` / `:next_href` — real navigation URLs for the previous/next month (the
      no-JS floor; when `nil` the arrow renders as an inert span).
    * `:week_starts_on` — `:sunday` (default) or `:monday`.
    * `:empty_cell_text` — text for an in-month day with zero events (default `""`).
    * `:event` (required slot, `:let={row}`) — renders ONE event from a day's row.
  """
  attr :id, :string, default: "calendar"
  attr :board, :any, required: true, doc: "a %Samen.Web.Board{} with Date group keys"
  attr :month, Date, required: true
  attr :today, Date, default: nil
  attr :prev_href, :string, default: nil
  attr :next_href, :string, default: nil
  attr :week_starts_on, :atom, default: :sunday
  attr :empty_cell_text, :string, default: ""
  slot :event, required: true, doc: "renders one event from a day's row (:let={row})"

  def calendar(assigns) do
    month = first_of_month(assigns.month)
    today = assigns.today || Date.utc_today()

    assigns =
      assigns
      |> assign(:month, month)
      |> assign(:today, today)
      |> assign(:weekdays, weekday_labels(assigns.week_starts_on))
      |> assign(:weeks, month_weeks(month, assigns.week_starts_on))
      |> assign(:day_map, day_map(assigns.board))
      |> assign(:month_label, month_label(month))

    ~H"""
    <div id={@id} class="cal" role="grid" aria-label={@month_label}>
      <header class="cal-h">
        <.nav_arrow href={@prev_href} label="Previous month" glyph="‹" id={"#{@id}-prev"} />
        <h2 class="cal-title" id={"#{@id}-title"}>{@month_label}</h2>
        <.nav_arrow href={@next_href} label="Next month" glyph="›" id={"#{@id}-next"} />
      </header>

      <div class="cal-wd" role="row">
        <span :for={wd <- @weekdays} class="cal-wd-c" role="columnheader">{wd}</span>
      </div>

      <div class="cal-grid">
        <div :for={week <- @weeks} class="cal-week" role="row">
          <%= for day <- week do %>
            <% group = Map.get(@day_map, day) %>
            <div
              class={cell_class(day, @month, @today)}
              id={"#{@id}-cell-#{Date.to_iso8601(day)}"}
              role="gridcell"
              data-date={Date.to_iso8601(day)}
            >
              <div class="cal-cell-h">
                <span class="cal-daynum">{day.day}</span>
                <span :if={day_count(group) > 0} class="cal-cell-n">{day_count(group)}</span>
              </div>

              <div class="cal-events">
                <article :for={row <- events(group)} class="cal-ev">
                  {render_slot(@event, row)}
                </article>

                <p :if={in_month?(day, @month) and events(group) == []} class="cal-cell-empty">
                  {@empty_cell_text}
                </p>

                <span :if={overflow(group) > 0} class="cal-more">+{overflow(group)} more</span>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr :href, :string, default: nil
  attr :label, :string, required: true
  attr :glyph, :string, required: true
  attr :id, :string, required: true

  defp nav_arrow(%{href: href} = assigns) when is_binary(href) do
    ~H"""
    <a href={@href} class="cal-nav" id={@id} rel="nofollow" aria-label={@label}>{@glyph}</a>
    """
  end

  defp nav_arrow(assigns) do
    ~H"""
    <span class="cal-nav cal-nav-off" id={@id} aria-hidden="true">{@glyph}</span>
    """
  end

  # -- public date helpers (thin, so the vertical mount stays ≈0-LOC) -----------

  @doc "Normalize any `Date` to the first of its month."
  def first_of_month(%Date{} = date), do: Date.beginning_of_month(date)

  @doc "The first day of the month BEFORE `date`'s month."
  def prev_month(%Date{} = date) do
    date |> first_of_month() |> Date.add(-1) |> first_of_month()
  end

  @doc "The first day of the month AFTER `date`'s month."
  def next_month(%Date{} = date) do
    date |> first_of_month() |> Date.end_of_month() |> Date.add(1)
  end

  @doc """
  Parse a `\"YYYY-MM\"` (or full ISO `\"YYYY-MM-DD\"`) month param to a first-of-month `Date`.
  Fail-safe: any nil/garbage value returns `default` (a hostile `?month=` never crashes the
  mount — the no-JS nav param is bounded, not trusted).
  """
  def parse_month(value, %Date{} = default) do
    with str when is_binary(str) <- value,
         {:ok, date} <- parse_iso_month(String.trim(str)) do
      first_of_month(date)
    else
      _ -> first_of_month(default)
    end
  end

  @doc "A human month label, e.g. `\"July 2026\"`."
  def month_label(%Date{month: m, year: y}), do: "#{Enum.at(@month_names, m - 1)} #{y}"

  # -- grid / bucket helpers ---------------------------------------------------

  defp parse_iso_month(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> Date.from_iso8601(str <> "-01")
    end
  end

  defp weekday_labels(:monday), do: @weekdays_mon
  defp weekday_labels(_), do: @weekdays_sun

  # The 0-based column offset of `date`'s weekday given the week-start.
  defp weekday_offset(%Date{} = date, :monday), do: Date.day_of_week(date, :monday) - 1
  defp weekday_offset(%Date{} = date, _sunday), do: rem(Date.day_of_week(date, :sunday) - 1, 7)

  # The month laid out as a list of weeks (each a 7-Date list), with leading/trailing days
  # from the adjacent months padding the grid so every row is full.
  defp month_weeks(%Date{} = month, week_starts_on) do
    start = first_of_month(month)
    lead = weekday_offset(start, week_starts_on)
    grid_start = Date.add(start, -lead)
    days_in_month = Date.days_in_month(start)
    total = ceil_div(lead + days_in_month, 7) * 7

    0..(total - 1)
    |> Enum.map(fn i -> Date.add(grid_start, i) end)
    |> Enum.chunk_every(7)
  end

  defp ceil_div(a, b), do: div(a + b - 1, b)

  # O(1) lookup: day Date -> its %Board.Group{}.
  defp day_map(%{groups: groups}), do: Map.new(groups, fn g -> {g.key, g} end)
  defp day_map(_), do: %{}

  defp events(nil), do: []
  defp events(%{rows: rows}), do: rows

  # The exact per-day total (aggregate count, or the loaded length when counting was off).
  defp day_count(nil), do: 0
  defp day_count(%{count: count}) when is_integer(count), do: count
  defp day_count(%{rows: rows}), do: length(rows)

  # Rows still un-loaded in a capped day (server-computed from the exact count → survives JS off).
  defp overflow(nil), do: 0
  defp overflow(%{has_more: false}), do: 0
  defp overflow(%{count: count, rows: rows}) when is_integer(count), do: max(count - length(rows), 0)
  defp overflow(_), do: 0

  defp in_month?(%Date{month: m, year: y}, %Date{month: m, year: y}), do: true
  defp in_month?(_, _), do: false

  defp cell_class(day, month, today) do
    [
      "cal-cell",
      if(in_month?(day, month), do: "cal-in", else: "cal-out"),
      if(day == today, do: "cal-today")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end
end
