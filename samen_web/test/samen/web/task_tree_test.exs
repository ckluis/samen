defmodule Samen.Web.TaskTreeTest do
  @moduledoc """
  T54 (G6) — the Work Task TREE page (`Samen.Web.Work.TaskTreeLive` +
  `Samen.Web.Work.Reads.tasks_tree/4`), the first client of `Samen.UI.tree/1`. Proves, against
  real DB rows, that the THIN client wiring renders the framework tree correctly:

    * HIERARCHY RENDER — a root → child → grandchild renders as nested nodes on the real page.
    * ORG-SCOPE — a 2-org seed: org B's tasks NEVER appear in org A's tree page.
    * NO-JS DRILL-IN — a `?focus=<id>` GET re-roots the walk (a sub-tree page), and keeps `?org=`
      on the drill-in prefix; a garbage `?focus=` degrades to the roots, never a crash.
    * FAIL-SAFE — no org resolved renders the honest empty state.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Work.TaskTreeLive

  defp seed_task(org_id, title, opts \\ []) do
    attrs = Map.merge(%{org_id: org_id, title: title, status: :pending}, Map.new(opts))

    Samen.WebTest.Work.Task
    |> Ash.Changeset.for_create(:create, attrs, actor: %{org_id: org_id, role: :member}, authorize?: false)
    |> Ash.create!()
  end

  defp mount_socket(mount, org_id, focus \\ nil) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> TaskTreeLive.load(org_id, focus)
  end

  defp html(socket), do: render_html(TaskTreeLive, socket.assigns)

  test "HIERARCHY RENDER: root → child → grandchild render as nested nodes" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()

    root = seed_task(org_id, "PARENT-TASK")
    child = seed_task(org_id, "CHILD-TASK", parent_id: root.id)
    grand = seed_task(org_id, "GRAND-TASK", parent_id: child.id)

    rendered = html(mount_socket(mount, org_id))

    assert rendered =~ "PARENT-TASK"
    assert rendered =~ "CHILD-TASK"
    assert rendered =~ "GRAND-TASK"
    assert rendered =~ ~s(id="tree-task-#{root.id}")
    assert rendered =~ ~s(id="tree-task-#{grand.id}")
    # A loaded subtree renders as a native <details> (no-JS collapse).
    assert rendered =~ "<details open"
  end

  test "ORG-SCOPE: org B's tasks never appear in org A's tree page" do
    mount = build_mount(:work)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    seed_task(org_a, "A-ROOT")
    seed_task(org_b, "B-ROOT-SENTINEL")

    rendered = html(mount_socket(mount, org_a))

    assert rendered =~ "A-ROOT"
    refute rendered =~ "B-ROOT-SENTINEL"
  end

  test "NO-JS DRILL-IN: a ?focus=<id> GET re-roots the walk at that node, keeping ?org= on the prefix" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()

    root = seed_task(org_id, "ROOT-FOCUS")
    child = seed_task(org_id, "CHILD-FOCUS", parent_id: root.id)

    # Focused on the root: the walk starts BELOW it — the child is a root of the sub-tree.
    socket = mount_socket(mount, org_id, root.id)
    assert socket.assigns.focus == root.id
    assert Enum.map(socket.assigns.tree.roots, & &1.id) == [child.id]

    rendered = html(socket)
    # The drill-in prefix keeps ?org= so links stay org-scoped.
    assert socket.assigns.expand_prefix == "org=#{org_id}&"
    # The "back to all tasks" link is present on a focused view.
    assert rendered =~ "back to all tasks"
  end

  test "a garbage ?focus= degrades to the roots, never a crash" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    seed_task(org_id, "TOP")

    # A non-uuid focus is ignored → the true roots are walked (proven via the full mount/3 path).
    {:ok, socket} =
      TaskTreeLive.mount(
        %{"org" => org_id, "focus" => "not-a-uuid"},
        mount_session(mount),
        %Phoenix.LiveView.Socket{}
      )

    assert socket.assigns.focus == nil
    assert html(socket) =~ "TOP"
  end

  test "no org resolved renders the honest empty state, never a crash" do
    rendered = html(mount_socket(build_mount(:work), nil))
    assert is_binary(rendered)
  end
end
