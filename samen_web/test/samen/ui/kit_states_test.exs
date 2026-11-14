defmodule Samen.UI.KitStatesTest do
  @moduledoc """
  The kit's unhappy-path states (evaluation 2026-11-13, audit-kit F01–F37): the loading / error /
  empty / nil-guard behaviour every data component gained, the in-flight button affordances, the
  total `translate_form_error`, the `social_links` allow-list, the palette link and the flash /
  connection notices.

  Every assertion is on RENDERED behaviour. Each new attr is paired with a positive control (the
  default render is unchanged), so a test here cannot pass by the feature never rendering.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Samen.Web.Board
  alias Samen.Web.Page
  alias Samen.Web.Series
  alias Samen.Web.Series.Point
  alias Samen.Web.Tree

  # -- slot helpers --------------------------------------------------------------

  defp slot(fun), do: [%{inner_block: fn _, arg -> fun.(arg) end}]
  defp raw(html), do: slot(fn _ -> Phoenix.HTML.raw(html) end)

  defp head, do: raw(~s(<th scope="col">Name</th>))
  defp row_slot, do: slot(fn item -> Phoenix.HTML.raw("<td>#{item.name}</td>") end)
  defp card_slot, do: slot(fn row -> Phoenix.HTML.raw(~s(<b class="c">#{row.name}</b>)) end)

  defp page(items), do: %Page{items: items, has_more: false, cursor: nil, page_size: 5}

  defp group(key, rows),
    do: %Board.Group{key: key, label: to_string(key), rows: rows, count: length(rows)}

  defp series(values) do
    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> %Point{key: "k#{i}", label: "L#{i}", value: v, raw: v} end)

    %Series{points: points}
  end

  # ---------------------------------------------------------------------------
  # error_state/1 + skeleton shapes
  # ---------------------------------------------------------------------------

  describe "error_state/1 and skeleton shapes" do
    test "error_state is role=alert, shows the body, and wires the retry event" do
      html =
        render_component(&Samen.UI.error_state/1, %{body: "Load failed", retry_event: "reload"})

      assert html =~ ~s(role="alert")
      assert html =~ "Something went wrong"
      assert html =~ "Load failed"
      assert html =~ ~s(phx-click="reload")
      assert html =~ "Try again"
    end

    test "without a retry event there is no button (positive control for the one above)" do
      html = render_component(&Samen.UI.error_state/1, %{})
      refute html =~ "<button"
      refute html =~ "phx-click"
    end

    test "skeleton shapes: rows (default) keeps today's markup, card/chart render a block" do
      rows = render_component(&Samen.UI.skeleton/1, %{rows: 2})
      assert rows =~ "skeleton-row"
      refute rows =~ "skeleton-block"
      refute rows =~ "skeleton-card"

      chart = render_component(&Samen.UI.skeleton/1, %{shape: "chart"})
      assert chart =~ "skeleton-chart"
      assert chart =~ "skeleton-block"
      refute chart =~ "skeleton-row"
    end
  end

  # ---------------------------------------------------------------------------
  # loading / error on every data component (F04)
  # ---------------------------------------------------------------------------

  # {name, component, assigns that render the happy path}
  defp data_components do
    board = %Board{groups: [group(:a, [%{id: 1, name: "HAPPY-BOARD"}])]}
    tree = %Tree{roots: []}

    [
      {"data_table", &Samen.UI.data_table/1, %{head: head(), inner_block: raw("<tr><td>HAPPY-TABLE</td></tr>")}},
      {"list_view", &Samen.UI.list_view/1,
       %{page: page([%{id: "1", name: "HAPPY-LIST"}]), head: head(), row: row_slot()}},
      {"board", &Samen.UI.board/1, %{board: board, card: card_slot()}},
      {"gallery", &Samen.UI.gallery/1, %{page: page([%{id: "1", name: "HAPPY-GALLERY"}]), card: card_slot()}},
      {"tree", &Samen.UI.tree/1, %{tree: tree, node: card_slot()}},
      {"calendar", &Samen.UI.calendar/1,
       %{board: %Board{groups: []}, month: ~D[2026-03-10], event: card_slot()}},
      {"gantt", &Samen.UI.gantt/1,
       %{
         board: %Board{groups: []},
         range_start: ~D[2026-03-01],
         range_end: ~D[2026-03-31],
         start_field: :start,
         bar: card_slot()
       }},
      {"bar_chart", &Samen.UI.bar_chart/1, %{series: series([1, 2])}},
      {"line_chart", &Samen.UI.line_chart/1, %{series: series([1, 2])}},
      {"pie_chart", &Samen.UI.pie_chart/1, %{series: series([1, 2])}},
      {"map", &Samen.UI.map/1, %{geo_set: %Samen.Web.GeoSet{}}},
      {"dashboard", &Samen.UI.dashboard/1, %{tile: [%{inner_block: fn _, _ -> "HAPPY-TILE" end}]}},
      {"timeline", &Samen.UI.timeline/1, %{entries: [%{id: 1, subject: "HAPPY-TL", type: :note}]}},
      {"metric", &Samen.UI.metric/1, %{label: "MRR", value: "HAPPY-METRIC"}}
    ]
  end

  test "loading renders the skeleton in place of the body, on every data component" do
    for {name, comp, base} <- data_components() do
      happy = render_component(comp, base)
      refute happy =~ "aria-busy", "#{name}: the default render must not be in a loading state"

      html = render_component(comp, Map.put(base, :loading, true))
      assert html =~ "aria-busy", "#{name}: loading must render the skeleton"
      refute html =~ "HAPPY-", "#{name}: loading must not render the body"
    end
  end

  test "error renders error_state (role=alert + message + retry) in place of the body" do
    for {name, comp, base} <- data_components() do
      html =
        render_component(
          comp,
          base |> Map.put(:error, "Query timed out") |> Map.put(:retry_event, "retry")
        )

      assert html =~ ~s(role="alert"), "#{name}: error must be announced"
      assert html =~ "Query timed out", "#{name}: error message missing"
      refute html =~ "HAPPY-", "#{name}: error must not render the body"

      # metric/dashboard degrade inline (no retry button); the rest carry the retry control.
      if name not in ["metric", "timeline"] do
        assert html =~ ~s(phx-click="retry"), "#{name}: retry event not wired"
      end
    end
  end

  test "error: true renders the generic message and a non-binary error is NEVER inspected" do
    secret = {:db_error, "vt_SECRET_TOKEN", %Samen.Masked{token: "vt_SECRET_TOKEN", label: :pii}}

    for {name, comp, base} <- data_components() do
      generic = render_component(comp, Map.put(base, :error, true))
      assert generic =~ ~s(role="alert"), "#{name}: error: true must still render the error state"

      html = render_component(comp, Map.put(base, :error, secret))
      assert html =~ ~s(role="alert")
      refute html =~ "vt_SECRET_TOKEN", "#{name}: an error term must not be inspected into the DOM"
      refute html =~ "db_error"
    end
  end

  test "error wins over loading" do
    html = render_component(&Samen.UI.board/1, %{board: nil, card: card_slot(), loading: true, error: "bad"})
    assert html =~ "bad"
    assert html =~ ~s(role="alert")
  end

  # ---------------------------------------------------------------------------
  # nil / unloaded collections never raise (F04)
  # ---------------------------------------------------------------------------

  describe "nil guards" do
    test "board: nil board and zero groups render the empty state, a real board still renders" do
      assert render_component(&Samen.UI.board/1, %{board: nil, card: card_slot()}) =~ "Nothing here yet."
      assert render_component(&Samen.UI.board/1, %{board: %Board{groups: []}, card: card_slot()}) =~ "board-empty"

      real = render_component(&Samen.UI.board/1, %{board: %Board{groups: [group(:a, [%{name: "ROW"}])]}, card: card_slot()})
      assert real =~ "ROW"
      refute real =~ "board-empty"
    end

    test "gallery: nil page renders the empty state" do
      html = render_component(&Samen.UI.gallery/1, %{page: nil, card: card_slot()})
      assert html =~ "Nothing here yet."
      refute html =~ "gallery-grid"
    end

    test "list_view: nil page renders the empty state instead of raising" do
      html = render_component(&Samen.UI.list_view/1, %{page: nil, head: head(), row: row_slot()})
      assert html =~ "Nothing here yet."
    end

    test "tree: nil tree renders zero roots" do
      html = render_component(&Samen.UI.tree/1, %{tree: nil, node: card_slot()})
      assert html =~ "tree-empty"
    end

    test "charts: a nil series renders 'No data' for bar, line and pie" do
      for comp <- [&Samen.UI.bar_chart/1, &Samen.UI.line_chart/1, &Samen.UI.pie_chart/1] do
        html = render_component(comp, %{series: nil})
        assert html =~ "No data"
      end
    end

    test "timeline: nil entries render the empty message" do
      html = render_component(&Samen.UI.timeline/1, %{entries: nil})
      assert html =~ "No activity yet."
    end

    test "calendar: nil board and nil month render a grid for the current month" do
      html = render_component(&Samen.UI.calendar/1, %{board: nil, month: nil, event: card_slot()})
      assert html =~ "cal-grid"
    end

    test "map: a nil geo_set renders the empty basemap" do
      html = render_component(&Samen.UI.map/1, %{geo_set: nil})
      assert html =~ "geo-map"
    end

    test "metric: a nil value renders an em dash" do
      html = render_component(&Samen.UI.metric/1, %{label: "MRR", value: nil})
      assert html =~ ~s(<span class="num">—</span>)
    end

    test "object_card: a tuple error reason does not raise and is not inspected into the DOM" do
      html = render_component(&Samen.UI.object_card/1, %{card: {:error, {:db, "vt_SECRET"}}})
      assert html =~ "Object not available"
      assert html =~ ~s(data-obj-error="error")
      refute html =~ "vt_SECRET"

      # positive control: an atom reason keeps today's attribute
      assert render_component(&Samen.UI.object_card/1, %{card: {:error, :not_found}}) =~
               ~s(data-obj-error="not_found")
    end
  end

  # ---------------------------------------------------------------------------
  # chart edge cases (F15–F17)
  # ---------------------------------------------------------------------------

  describe "chart geometry edge cases" do
    test "a one-point bar and line chart render finite geometry" do
      bars = Samen.UI.Chart.bar_geometry(series([5]))
      assert [%{height: h, width: w}] = bars
      assert h > 0 and w > 0

      assert [%{cx: cx, cy: cy}] = Samen.UI.Chart.line_geometry(series([5]))
      assert is_float(cx) and is_float(cy)
    end

    test "all-zero values: no division by zero, bars have zero height" do
      assert [%{height: +0.0}, %{height: +0.0}] = Samen.UI.Chart.bar_geometry(series([0, 0]))
      assert [_, _] = Samen.UI.Chart.line_geometry(series([0, 0]))
      assert Samen.UI.Chart.pie_geometry(series([0, 0])) == []
      assert render_component(&Samen.UI.pie_chart/1, %{series: series([0, 0])}) =~ "No data"
    end

    test "negative and nil values clamp to zero instead of producing invalid SVG or raising" do
      [neg, pos] = Samen.UI.Chart.bar_geometry(series([-5, 10]))
      assert neg.height == 0.0
      assert pos.height > 0

      assert [%{height: +0.0}, %{height: h}] = Samen.UI.Chart.bar_geometry(series([nil, 4]))
      assert h > 0

      html = render_component(&Samen.UI.line_chart/1, %{series: series([nil, -3, 4])})
      refute html =~ "NaN"
      refute html =~ ~s(cy="-)

      pie = Samen.UI.Chart.pie_geometry(series([-5, 5]))
      assert [%{pct: neg_pct}, %{pct: 100.0}] = pie
      assert neg_pct == 0.0
    end

    test "the accessible data table keeps the real (negative) figure" do
      html = render_component(&Samen.UI.bar_chart/1, %{series: series([-5, 10])})
      assert html =~ "-5"
    end
  end

  # ---------------------------------------------------------------------------
  # empty states (F21)
  # ---------------------------------------------------------------------------

  describe "empty states" do
    test "data_table carries a neutral empty message, overridable by the :empty slot" do
      html = render_component(&Samen.UI.data_table/1, %{head: head(), inner_block: raw("")})
      assert html =~ ~s(class="table-empty")
      assert html =~ "Nothing to show."

      custom = render_component(&Samen.UI.data_table/1, %{head: head(), inner_block: raw(""), empty_text: "No invoices"})
      assert custom =~ "No invoices"

      slotted =
        render_component(&Samen.UI.data_table/1, %{
          head: head(),
          inner_block: raw(""),
          empty: raw("<em>SLOTTED-EMPTY</em>")
        })

      assert slotted =~ "SLOTTED-EMPTY"
    end

    test "list_view: a filter that matched nothing says 'No matches' with a clear control; first-run empty is unchanged" do
      no_match =
        render_component(&Samen.UI.list_view/1, %{page: page([]), head: head(), row: row_slot(), filter: "zzz"})

      assert no_match =~ "No matches"
      assert no_match =~ "zzz"
      assert no_match =~ ~s(phx-click="filter")
      assert no_match =~ ~s(phx-value-filter="")
      assert no_match =~ "Clear filter"
      refute no_match =~ "Nothing here yet."

      first_run = render_component(&Samen.UI.list_view/1, %{page: page([]), head: head(), row: row_slot()})
      assert first_run =~ "Nothing here yet."
      refute first_run =~ "No matches"
      refute first_run =~ "Clear filter"
    end

    test "list_view: a blank filter is first-run empty, not 'no matches'" do
      html = render_component(&Samen.UI.list_view/1, %{page: page([]), head: head(), row: row_slot(), filter: "  "})
      assert html =~ "Nothing here yet."
    end

    test "dashboard with zero tiles renders an empty state; with tiles it does not" do
      assert render_component(&Samen.UI.dashboard/1, %{tile: []}) =~ "Nothing to show yet."

      full = render_component(&Samen.UI.dashboard/1, %{tile: [%{inner_block: fn _, _ -> "T" end}]})
      refute full =~ "Nothing to show yet."
      assert full =~ "dash-tile"
    end

    test "dashboard isolates one failing tile; the others still render" do
      html =
        render_component(&Samen.UI.dashboard/1, %{
          tile: [
            %{inner_block: fn _, _ -> "GOOD-TILE" end},
            %{inner_block: fn _, _ -> "BAD-TILE" end, error: "chart failed"},
            %{inner_block: fn _, _ -> "SLOW-TILE" end, loading: true}
          ]
        })

      assert html =~ "GOOD-TILE"
      assert html =~ "chart failed"
      refute html =~ "BAD-TILE"
      refute html =~ "SLOW-TILE"
      assert html =~ "aria-busy"
    end
  end

  # ---------------------------------------------------------------------------
  # gantt: stacking is opt-in (F09)
  # ---------------------------------------------------------------------------

  describe "gantt stack" do
    defp overlapping_board do
      %Board{
        groups: [
          group(:lane, [
            %{id: 1, name: "A", start: ~D[2026-03-02], finish: ~D[2026-03-10]},
            %{id: 2, name: "B", start: ~D[2026-03-02], finish: ~D[2026-03-10]}
          ])
        ]
      }
    end

    defp gantt_html(extra) do
      render_component(
        &Samen.UI.gantt/1,
        Map.merge(
          %{
            board: overlapping_board(),
            range_start: ~D[2026-03-01],
            range_end: ~D[2026-03-31],
            start_field: :start,
            end_field: :finish,
            bar: card_slot()
          },
          extra
        )
      )
    end

    test "default output is unchanged (no top offsets, no min-height)" do
      html = gantt_html(%{})
      refute html =~ "top:"
      refute html =~ "min-height"
    end

    test "stack: true gives each concurrent bar its own row" do
      html = gantt_html(%{stack: true})
      assert html =~ "top:6px"
      assert html =~ "top:32px"
      assert html =~ "min-height:64px"
    end
  end

  # ---------------------------------------------------------------------------
  # button / delete_confirm in-flight affordances (F06)
  # ---------------------------------------------------------------------------

  describe "button busy_text and confirm" do
    test "defaults reproduce today's markup" do
      html = render_component(&Samen.UI.button/1, %{inner_block: raw("Go")})
      assert html =~ ~s(class="btn")
      refute html =~ "phx-disable-with"
      refute html =~ "data-confirm"
    end

    test "busy_text maps to phx-disable-with and confirm to data-confirm" do
      html =
        render_component(&Samen.UI.button/1, %{
          inner_block: raw("Archive"),
          busy_text: "Archiving…",
          confirm: "Archive this?",
          rest: %{"phx-click": "archive"}
        })

      assert html =~ ~s(phx-disable-with="Archiving…")
      assert html =~ ~s(data-confirm="Archive this?")
      assert html =~ ~s(phx-click="archive")
    end

    test "delete_confirm disables itself in flight and still carries its confirm interlock" do
      html = render_component(&Samen.UI.delete_confirm/1, %{})
      assert html =~ ~s(phx-disable-with="Deleting…")
      assert html =~ "data-confirm="
    end

    test "list_view pagination and bulk controls carry a busy state" do
      html =
        render_component(&Samen.UI.list_view/1, %{
          page: %Page{items: [%{id: "1", name: "A"}], has_more: true, cursor: nil, page_size: 5},
          head: head(),
          row: row_slot(),
          selectable: true,
          selected: MapSet.new(["1"]),
          bulk_actions: [%{name: "archive", label: "Archive"}]
        })

      assert html =~ ~s(phx-disable-with="…")
      assert html =~ ~s(phx-disable-with="Working…")
    end

    test "simple_form exposes its default busy text for submit buttons" do
      form = Phoenix.Component.to_form(%{}, as: :f)
      html = render_component(&Samen.UI.simple_form/1, %{for: form, inner_block: raw("")})
      assert html =~ ~s(data-busy-text="Saving…")
    end
  end

  # ---------------------------------------------------------------------------
  # translate_form_error is total (F05)
  # ---------------------------------------------------------------------------

  describe "form_field error rendering is total" do
    defp field_with_errors(errors) do
      form = Phoenix.Component.to_form(%{"name" => ""}, as: :user, errors: Enum.map(errors, &{:name, &1}))
      form[:name]
    end

    defp errors_html(errors) do
      render_component(&Samen.UI.form_field/1, %{field: field_with_errors(errors), label: "Name"})
    end

    test "positive control: the {msg, opts} shape still interpolates" do
      html = errors_html([{"should be at least %{count} character(s)", [count: 3, validation: :length]}])
      assert html =~ "should be at least 3 character(s)"
      assert html =~ "field-invalid"
    end

    test "a plain binary, an atom, an Ash-style struct and nil all render instead of raising" do
      html = errors_html(["is required", :taken, %{message: "was already used"}, nil])
      assert html =~ "is required"
      assert html =~ "taken"
      assert html =~ "was already used"
      assert html =~ "is invalid"
    end

    test "a tuple opt value (type: {:array, _}) does not raise Protocol.UndefinedError" do
      html = errors_html([{"is not a valid %{type}", [type: {:array, :string}]}])
      assert html =~ "is not a valid"
      assert html =~ "array"
    end

    test "non-enumerable opts keep the message; an unknown term is generic and never inspected" do
      assert errors_html([{"bad value", :oops}]) =~ "bad value"

      html = errors_html([{:weird, "vt_SECRET_TOKEN"}, %Samen.Masked{token: "vt_SECRET_TOKEN", label: :pii}])
      assert html =~ "is invalid"
      refute html =~ "vt_SECRET_TOKEN"
    end
  end

  # ---------------------------------------------------------------------------
  # social_links allow-list (F12 — security)
  # ---------------------------------------------------------------------------

  describe "social_links allow-list" do
    defp social(custom), do: render_component(&Samen.UI.social_links/1, %{custom: custom})

    test "http(s) URLs and bare handles become links" do
      html =
        social(%{
          "social_linkedin" => "https://www.linkedin.com/in/jdoe",
          "social_twitter" => "@jdoe",
          "social_github" => "jdoe"
        })

      assert html =~ ~s(href="https://www.linkedin.com/in/jdoe")
      assert html =~ ~s(href="https://x.com/jdoe")
      assert html =~ ~s(href="https://github.com/jdoe")
      assert html =~ ~s(rel="noopener noreferrer")
    end

    test "javascript:, data:, mailto: and other schemes are NEVER an href — they render as text" do
      for bad <- [
            "javascript:alert(1)",
            "  JaVaScRiPt:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "vbscript:msgbox(1)",
            "mailto:a@b.co",
            "java\nscript:alert(1)",
            "//evil.example/x",
            "ftp://example.com/x",
            "https://",
            "https://exa mple.com",
            ~s(https://example.com/"onmouseover="x),
            "not a handle!"
          ] do
        html = social(%{"social_github" => bad})
        refute html =~ "<a ", "#{inspect(bad)} must not become a link"
        refute html =~ "href=", "#{inspect(bad)} must not reach an href"
        assert html =~ "social-text", "#{inspect(bad)} should still show as text"
      end
    end

    test "the text fallback is HTML-escaped" do
      html = social(%{"social_github" => "<script>alert(1)</script>"})
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "blank and non-binary values render nothing" do
      assert String.trim(social(%{"social_github" => "  ", "social_twitter" => 5, "social_linkedin" => nil})) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # command palette links (F02)
  # ---------------------------------------------------------------------------

  describe "command_palette hit links" do
    defp hit(extra \\ %{}) do
      Map.merge(
        %{resource_name: "Acme.Crm.Person", display: %{name: "Ada"}, id: "p1"},
        extra
      )
    end

    defp palette(results, extra \\ %{}) do
      render_component(&Samen.UI.command_palette/1, Map.merge(%{results: results, q: "ad"}, extra))
    end

    test "without a destination a hit renders exactly as before (no link)" do
      html = palette([hit()])
      assert html =~ "Ada"
      refute html =~ "<a "
    end

    test "an href function supplies the destination" do
      html = palette([hit()], %{href: fn r -> "/crm/contacts/#{r.id}" end})
      assert html =~ ~s(<a href="/crm/contacts/p1")
      assert html =~ "Ada"
    end

    test "a result carrying :path or :href links without a function" do
      assert palette([hit(%{path: "/crm/contacts/p1"})]) =~ ~s(href="/crm/contacts/p1")
      assert palette([hit(%{href: "/x?y=1"})]) =~ ~s(href="/x?y=1")
    end

    test "only same-origin paths link: javascript:, absolute, protocol-relative and nil are ignored" do
      for bad <- ["javascript:alert(1)", "https://evil.example/", "//evil.example", "/\\evil.example", nil, 5] do
        html = palette([hit()], %{href: fn _ -> bad end})
        refute html =~ "<a ", "#{inspect(bad)} must not link"
        assert html =~ "Ada"
      end
    end

    test "a raising href function degrades to the unlinked hit" do
      html = palette([hit()], %{href: fn _ -> raise "boom" end})
      assert html =~ "Ada"
      refute html =~ "<a "
    end
  end

  # ---------------------------------------------------------------------------
  # host_nav_extra (F22)
  # ---------------------------------------------------------------------------

  describe "host_nav_extra with malformed items" do
    def mixed_items(_org),
      do: %{
        label: "Ops",
        items: [
          %{label: "Good link", href: "/ok"},
          %{label: "No href"},
          %{href: "/no-label"},
          %{label: "Nil href", href: nil},
          :junk
        ]
      }

    test "drops the bad items and renders the good one instead of raising KeyError" do
      mount =
        Samen.Web.Mount.new(:crm, __MODULE__, Samen.WebTest.Repo,
          labels: %{host_nav_extra: {__MODULE__, :mixed_items, []}}
        )

      html = render_component(&Samen.UI.host_nav_extra/1, %{mount: mount, org_id: "O1"})
      assert html =~ "Good link"
      assert html =~ ~s(href="/ok")
      refute html =~ "No href"
      refute html =~ "no-label"
      refute html =~ "Nil href"
    end
  end

  describe "host_nav_extra with a RAISING resolver" do
    def raising_nav(_org), do: raise("resolver down")

    test "omits the group but reports the failure by name; a working resolver logs nothing" do
      mount = Samen.Web.Mount.new(:crm, __MODULE__, Samen.WebTest.Repo, labels: %{host_nav_extra: {__MODULE__, :raising_nav, []}})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html = render_component(&Samen.UI.host_nav_extra/1, %{mount: mount, org_id: "O1"})
          refute html =~ "Ops"
        end)

      assert log =~ "host_nav_extra"
      assert log =~ "RuntimeError"

      ok = Samen.Web.Mount.new(:crm, __MODULE__, Samen.WebTest.Repo, labels: %{host_nav_extra: {__MODULE__, :mixed_items, []}})
      assert ExUnit.CaptureLog.capture_log(fn -> render_component(&Samen.UI.host_nav_extra/1, %{mount: ok, org_id: "O1"}) end) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # flash_group / connection banner (F07)
  # ---------------------------------------------------------------------------

  describe "flash_group/1" do
    test "renders info as role=status and error as role=alert, dismissible with JS off" do
      html =
        render_component(&Samen.UI.flash_group/1, %{
          flash: %{"info" => "Saved", "error" => "Could not save"}
        })

      assert html =~ "Saved"
      assert html =~ "Could not save"
      assert html =~ ~s(role="status")
      assert html =~ ~s(role="alert")
      # JS-off dismissal: a checkbox + label pair; JS-on: lv:clear-flash
      assert html =~ ~s(type="checkbox")
      assert html =~ ~s(for="flash-group-error-x")
      assert html =~ "lv:clear-flash"
    end

    test "renders nothing for an empty or blank flash, and ignores non-display keys" do
      assert String.trim(render_component(&Samen.UI.flash_group/1, %{flash: %{}})) == ""
      assert String.trim(render_component(&Samen.UI.flash_group/1, %{flash: %{"info" => "  "}})) == ""

      html =
        render_component(&Samen.UI.flash_group/1, %{
          flash: %{"totp_recovery_codes" => "AAAA-BBBB\nCCCC-DDDD", "info" => "ok"}
        })

      assert html =~ "ok"
      refute html =~ "AAAA-BBBB"
    end

    test "the message is HTML-escaped" do
      html = render_component(&Samen.UI.flash_group/1, %{flash: %{"error" => "<script>x</script>"}})
      refute html =~ "<script>"
    end
  end

  test "connection_banner is hidden by default and driven by the phx-disconnected / phx-connected bindings" do
    html = render_component(&Samen.UI.connection_banner/1, %{})
    assert html =~ "hidden"
    assert html =~ "phx-disconnected"
    assert html =~ "phx-connected"
    assert html =~ "reconnecting"
    assert html =~ ~s(role="status")
  end

  describe "layouts" do
    test "the LiveView layout renders flash + banner once, around the inner content" do
      html =
        render_component(&Samen.Web.Layouts.app/1, %{
          flash: %{"error" => "Boom"},
          inner_content: Phoenix.HTML.raw("<p id=\"inner\">INNER</p>")
        })

      assert html =~ "Boom"
      assert html =~ "connection-banner"
      assert html =~ "INNER"
      assert length(String.split(html, "Boom")) == 2, "the flash must render exactly once"
    end

    test "the root layout renders the conn flash on a controller page, but not on a LiveView page" do
      base = %{samen_layout_title: "T", inner_content: Phoenix.HTML.raw("<p>X</p>"), flash: %{"info" => "FROM-CONN"}}

      controller = Plug.Test.conn(:get, "/")
      lv = Plug.Conn.put_private(controller, :phoenix_live_view, {SomeLive, [], %{}})

      on_controller = render_component(&Samen.Web.Layouts.root/1, Map.put(base, :conn, controller))
      assert on_controller =~ "FROM-CONN"

      on_lv = render_component(&Samen.Web.Layouts.root/1, Map.put(base, :conn, lv))
      refute on_lv =~ "FROM-CONN", "a LiveView page renders its flash from app/1, never twice"
    end
  end

  # ---------------------------------------------------------------------------
  # shell: keyboard-reachable drawer toggle (F03)
  # ---------------------------------------------------------------------------

  test "app_shell: the drawer toggle is a real labelled checkbox (not aria-hidden / tabindex -1)" do
    html =
      render_component(&Samen.UI.app_shell/1, %{
        sidebar: raw(~s(<aside class="side" id="samen-nav">nav</aside>)),
        inner_block: raw("<p>main</p>")
      })

    [checkbox] = Regex.run(~r/<input[^>]*samen-nav-toggle[^>]*>/s, html)
    assert checkbox =~ ~s(aria-label="Toggle navigation menu")
    assert checkbox =~ ~s(aria-controls="samen-nav")
    refute checkbox =~ "tabindex"
    refute checkbox =~ "aria-hidden"
  end
end
