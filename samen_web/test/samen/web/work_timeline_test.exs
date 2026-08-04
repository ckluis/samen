defmodule Samen.Web.WorkTimelineTest do
  @moduledoc """
  End-to-end proofs for the G3 TIMELINE/Gantt view (T53) — the Work Tasks timeline as the FIRST
  client of the generic `Samen.Web.Reads.timeline_window!/3` rendered through `Samen.UI.gantt/1`.
  Each proof is anti-tautology (a positive control anchors every guard):

    * LANES/BARS — a seeded window renders status lanes and each task as a bar in its lane, all in
      the server-rendered DOM (the no-JS floor).
    * ORG-SCOPE (sabotage-refutable) — a 2-org seed: org B's tasks NEVER appear on org A's timeline
      (and DO appear on org B's own — the refutation control).
    * NO-JS NAVIGATION — prev/next are real `<a href="?from=YYYY-MM-DD">` links, and driving
      `handle_params/3` with a `from` param actually re-windows the read (a task present in the
      default window is absent when navigated to a far-past window — proving the param drives it).
    * MASKING POSTURE — Tasks are NON-PII and the axis fields are non-vaulted, so NO bar field
      masks (documented; a real vaulted sibling field anchors the non-vacuity of the claim).
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Mount
  alias Samen.Web.Work.TimelineLive

  @task Samen.WebTest.Work.Task
  @person Samen.WebTest.Crm.Person

  defp seed_task(org_id, title, status \\ :pending, due_at \\ nil) do
    @task
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, title: title, status: status, due_at: due_at},
      actor: %{org_id: org_id, role: :member},
      authorize?: false
    )
    |> Ash.create!()
  end

  # Drive the LiveView's real handle_params (the no-JS window-nav path) and render to HTML.
  defp render_params(mount, org_id, params) do
    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(
        samen_mount: mount,
        samen_acting_as: false,
        org_id: org_id,
        from: Date.utc_today()
      )

    {:noreply, socket} = TimelineLive.handle_params(params, "http://localhost/work/timeline", socket)
    render_html(TimelineLive, socket.assigns)
  end

  # -- LANES / BARS ------------------------------------------------------------

  test "renders status lanes with each task as a bar in the server-rendered DOM" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    # inserted_at is ~now, which sits inside the default window (today-7 .. today+21).
    for i <- 1..3, do: seed_task(org_id, "TL-TASK-#{i}", :pending, DateTime.add(DateTime.utc_now(), 3, :day))

    html = render_live(TimelineLive, mount, [org_id])

    # The Gantt container, its status lanes, and the axis are present …
    assert html =~ ~s(class="gantt")
    assert html =~ ~s(id="work-gantt")
    assert html =~ ~s(id="work-gantt-lane-pending")
    assert html =~ "Pending"
    assert html =~ ~s(class="gantt-tick")
    # … and each task renders as a positioned bar (the bar carries a server-computed style).
    assert html =~ "TL-TASK-1"
    assert html =~ "TL-TASK-3"
    assert html =~ "task-bar-"
    assert html =~ "gantt-bar"
    assert html =~ "left:"
  end

  # -- ORG-SCOPE (sabotage-refutable) ------------------------------------------

  test "ORG-SCOPE: org B's tasks NEVER appear on org A's timeline" do
    mount = build_mount(:work)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    for i <- 1..2, do: seed_task(org_a, "A-TASK-#{i}")
    for i <- 1..4, do: seed_task(org_b, "B-TASK-#{i}")

    a_html = render_live(TimelineLive, mount, [org_a])
    b_html = render_live(TimelineLive, mount, [org_b])

    # Org A's timeline shows ONLY org A tasks; org B's are absent …
    assert a_html =~ "A-TASK-1"
    refute a_html =~ "B-TASK-1"
    refute a_html =~ "B-TASK-4"

    # … and the refutation control: org B's tasks DO appear on org B's OWN timeline (so the
    # absence above is real org-scoping, not a seed that never rendered anywhere).
    assert b_html =~ "B-TASK-1"
    refute b_html =~ "A-TASK-1"

    # Reads-level cross-check: every bar on org A's timeline is org A's.
    scope_a = Mount.scope(mount, org_a)
    range = {DateTime.new!(Date.add(Date.utc_today(), -7), ~T[00:00:00], "Etc/UTC"),
             DateTime.new!(Date.add(Date.utc_today(), 21), ~T[00:00:00], "Etc/UTC")}
    %{board: board} = Samen.Web.Work.Reads.tasks_timeline(mount, scope_a, range)
    a_ids = board.groups |> Enum.flat_map(& &1.rows) |> MapSet.new(& &1.id)

    b_ids =
      @task
      |> Ash.Query.filter(org_id == ^org_b)
      |> Ash.read!(scope: Mount.scope(mount, org_b))
      |> MapSet.new(& &1.id)

    assert MapSet.size(b_ids) == 4
    assert MapSet.disjoint?(a_ids, b_ids)
  end

  # -- NO-JS NAVIGATION --------------------------------------------------------

  test "NO-JS NAV: prev/next are real window links and a ?from= param re-windows the read" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    seed_task(org_id, "NOW-TASK")

    # Default render (a window around today): the freshly-created task is PRESENT …
    default_html = render_live(TimelineLive, mount, [org_id])
    assert default_html =~ "NOW-TASK"
    # … and prev/next navigation are REAL links carrying a ?from= param (no JS needed).
    # (HEEx escapes `&` → `&amp;` in the href, so match the param, not the raw &.)
    assert default_html =~ ~s(<a href="?org=#{org_id})
    assert default_html =~ "from="
    assert default_html =~ ~s(class="gantt-nav")

    # Navigating to a FAR-PAST window via the PARAM (handle_params, not JS) drops the task —
    # proving the ?from= param actually drives the window, so a JS-off client can navigate.
    nav_html = render_params(mount, org_id, %{"org" => org_id, "from" => "2020-01-01"})
    refute nav_html =~ "NOW-TASK"
  end

  test "NO-JS NAV: a hostile/garbage ?from= is parsed fail-safe, never a crash" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    seed_task(org_id, "SAFE-TASK")

    # A garbage from param must NOT crash the mount — it falls back to the default window,
    # which is around today, so the freshly-created task still renders.
    html = render_params(mount, org_id, %{"org" => org_id, "from" => "not-a-date"})
    assert html =~ ~s(class="gantt")
    assert html =~ "SAFE-TASK"
  end

  # -- MASKING POSTURE ---------------------------------------------------------

  test "MASKING POSTURE: no bar field is vault-routed, so no per-plane proof is required" do
    # The axis fields and every rendered bar field are NON-vaulted …
    refute Samen.Pii.Info.vault_routed?(@task, :inserted_at)
    refute Samen.Pii.Info.vault_routed?(@task, :due_at)
    refute Samen.Pii.Info.vault_routed?(@task, :title)
    refute Samen.Pii.Info.vault_routed?(@task, :priority)
    refute Samen.Pii.Info.vault_routed?(@task, :status)
    # … anchored against a REAL vaulted field on a sibling resource, so "non-vaulted" is a live
    # discriminator, not a predicate that returns false for everything.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
  end
end
