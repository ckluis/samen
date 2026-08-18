defmodule Samen.Web.ReadsTreeTest do
  @moduledoc """
  The GENERIC hierarchical read primitive (`Samen.Web.Reads.tree!/3`, G6/WS-G) — the
  depth-bounded, cycle-safe, per-parent-bounded self-referential walk a tree view consumes. Each
  proof is anti-tautology (a positive control anchors every guard). Exercised against the Work
  `Task` via its `belongs_to :parent` pointer (`:parent_id`). The hierarchy HAZARDS get explicit,
  dedicated proofs:

    * HIERARCHY — a root → child → grandchild nests correctly (depths 0/1/2).
    * DEPTH BOUND — a chain deeper than `max_depth` stops at the boundary (a `:depth`-truncated
      node), never an unbounded descent (positive control: a larger cap loads the whole chain).
    * CYCLE-SAFE — CORRUPT cyclic data (self-parent, and an A↔B cycle — written by RAW SQL to
      bypass the write-time CycleGuard, because a READ must never trust the data) TERMINATES: the
      revisited node is a `:cycle` leaf, not an infinite loop / stack overflow (proven under an
      explicit timeout so a regression HANGS the assertion, it doesn't just slow it).
    * PER-LEVEL CAP — a node with more children than `sibling_limit` returns the cap +
      `has_more_children` + exact `child_count` ("+N more"), not the whole fan-out (positive
      control: an under-cap node returns all).
    * NODE BUDGET — a deep chain past `max_nodes` stops (a `:budget`-truncated node), bounding the
      whole walk (positive control: a bigger budget loads the chain).
    * ORG-SCOPE AT EVERY LEVEL — a 2-org seed where an org-B node's `parent_id` points AT org A's
      root (forced by RAW SQL): org B's node NEVER appears as a child in org A's tree
      (sabotage-refutable — the SAME structural pointer resolves to that node under org B's OWN
      scope, proving org-scope is what hides it, not a dead read).
    * MASKING (INV-1) — a VAULTED parent field is REFUSED (MaskedGroupKeyError), anchored against
      a real vaulted sibling; the Task parent/node fields are verified NON-vaulted.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Mount
  alias Samen.Web.Reads
  alias Samen.Web.Reads.MaskedGroupKeyError
  alias Samen.Web.Tree

  @task Samen.WebTest.Work.Task
  @person Samen.WebTest.Crm.Person

  defp seed_task(org_id, title, opts \\ []) do
    attrs =
      %{org_id: org_id, title: title, status: :pending}
      |> Map.merge(Map.new(opts))

    @task
    |> Ash.Changeset.for_create(:create, attrs, actor: %{org_id: org_id, role: :member}, authorize?: false)
    |> Ash.create!()
  end

  # RAW-SQL reparent — bypass the write-time CycleGuard + SameOrgFk to plant the exact CORRUPT
  # data a READ must survive (a cycle, or a cross-org parent pointer). The read must never trust
  # `parent_id`, so this is the only honest way to seed the hazard.
  defp force_parent!(child_id, parent_id) do
    table = AshPostgres.DataLayer.Info.table(@task)
    id_col = col(:id)
    parent_col = col(:parent_id)
    {:ok, cbin} = Ecto.UUID.dump(child_id)
    {:ok, pbin} = Ecto.UUID.dump(parent_id)

    Samen.WebTest.Repo.query!(
      "UPDATE #{table} SET #{parent_col} = $1 WHERE #{id_col} = $2",
      [pbin, cbin]
    )

    :ok
  end

  defp col(name) do
    attr = Ash.Resource.Info.attribute(@task, name)
    to_string(attr.source || attr.name)
  end

  defp build_tree(scope, opts) do
    Mount.resource(build_mount(:work), Task)
    |> Ash.Query.ensure_selected([:title, :status, :parent_id])
    |> Reads.tree!(:parent_id, [scope: scope] ++ opts)
  end

  defp node_ids(nodes), do: Enum.map(nodes, & &1.id)

  defp find(nodes, id), do: Enum.find(nodes, &(&1.id == id))

  # -- HIERARCHY ---------------------------------------------------------------

  test "HIERARCHY: a root → child → grandchild nests correctly (depths 0/1/2)" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    root = seed_task(org_id, "ROOT")
    child = seed_task(org_id, "CHILD", parent_id: root.id)
    grand = seed_task(org_id, "GRAND", parent_id: child.id)

    tree = build_tree(scope, [])

    assert node_ids(tree.roots) == [root.id]
    root_node = hd(tree.roots)
    assert root_node.depth == 0

    child_node = find(root_node.children, child.id)
    assert child_node
    assert child_node.depth == 1

    grand_node = find(child_node.children, grand.id)
    assert grand_node
    assert grand_node.depth == 2
    assert grand_node.record.title == "GRAND"
  end

  # -- DEPTH BOUND -------------------------------------------------------------

  test "DEPTH BOUND: a chain deeper than max_depth stops at the boundary (:depth), not forever" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    r = seed_task(org_id, "R")
    c1 = seed_task(org_id, "C1", parent_id: r.id)
    c2 = seed_task(org_id, "C2", parent_id: c1.id)
    _c3 = seed_task(org_id, "C3", parent_id: c2.id)

    # max_depth 2 → depth-0 (R) and depth-1 (C1) load; C1 is the boundary, C2 is refused.
    tree = build_tree(scope, max_depth: 2)

    root_node = hd(tree.roots)
    c1_node = find(root_node.children, c1.id)
    assert c1_node.depth == 1
    assert c1_node.truncated == :depth
    assert c1_node.children == []
    assert c1_node.expandable?
    assert tree.node_count == 2

    # Positive control: a larger depth loads the whole chain (the bound is a live discriminator).
    deep = build_tree(scope, max_depth: 8)
    deep_c1 = deep |> Map.fetch!(:roots) |> hd() |> Map.fetch!(:children) |> find(c1.id)
    assert find(deep_c1.children, c2.id)
    assert deep.node_count == 4
  end

  # -- CYCLE-SAFE (explicit termination) ---------------------------------------

  test "CYCLE-SAFE: a self-parent node TERMINATES as a :cycle leaf (no infinite loop)" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    s = seed_task(org_id, "SELF")
    force_parent!(s.id, s.id)

    # Under an explicit timeout: a regression that infinite-loops HANGS here (caught), a correct
    # walk returns at once. (Shared SQL sandbox lets the spawned task use the connection.)
    task = Task.async(fn -> build_tree(scope, root: s.id) end)
    tree = Task.await(task, 5_000)

    assert length(tree.roots) == 1
    only = hd(tree.roots)
    assert only.id == s.id
    assert only.truncated == :cycle
    assert only.children == []
  end

  test "CYCLE-SAFE: an A↔B cycle TERMINATES (the revisited node is a :cycle leaf, not a loop)" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    a = seed_task(org_id, "A")
    b = seed_task(org_id, "B", parent_id: a.id)
    # Corrupt into a 2-cycle: A.parent=B ∧ B.parent=A.
    force_parent!(a.id, b.id)

    task = Task.async(fn -> build_tree(scope, root: a.id) end)
    tree = Task.await(task, 5_000)

    # children-of-A = {B}; children-of-B = {A}, but A is already on the path → :cycle, stop.
    assert node_ids(tree.roots) == [b.id]
    b_node = hd(tree.roots)
    a_again = find(b_node.children, a.id)
    assert a_again
    assert a_again.truncated == :cycle
    assert a_again.children == []
    # Bounded: exactly the two distinct nodes were materialized, never more.
    assert tree.node_count == 2
  end

  # -- PER-LEVEL CAP -----------------------------------------------------------

  test "PER-LEVEL CAP: a node over sibling_limit returns cap + has_more + exact count" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    hot = seed_task(org_id, "HOT")
    for i <- 1..5, do: seed_task(org_id, "K-#{i}", parent_id: hot.id)

    cold = seed_task(org_id, "COLD")
    for i <- 1..2, do: seed_task(org_id, "U-#{i}", parent_id: cold.id)

    tree = build_tree(scope, sibling_limit: 3)

    hot_node = find(tree.roots, hot.id)
    assert length(hot_node.children) == 3
    assert hot_node.has_more_children
    assert hot_node.child_count == 5
    assert tree.sibling_limit == 3

    # Positive control: an under-cap node returns all, has_more false.
    cold_node = find(tree.roots, cold.id)
    assert length(cold_node.children) == 2
    refute cold_node.has_more_children
    assert cold_node.child_count == 2
  end

  # -- NODE BUDGET -------------------------------------------------------------

  test "NODE BUDGET: a deep chain past max_nodes stops (:budget), bounding the whole walk" do
    mount = build_mount(:work)
    org_id = Ash.UUID.generate()
    scope = Mount.scope(mount, org_id)

    r = seed_task(org_id, "N0")
    c1 = seed_task(org_id, "N1", parent_id: r.id)
    c2 = seed_task(org_id, "N2", parent_id: c1.id)
    _c3 = seed_task(org_id, "N3", parent_id: c2.id)

    tree = build_tree(scope, max_nodes: 3, sibling_limit: 50, max_depth: 32)

    assert tree.node_count == 3
    assert tree.truncated?

    c2_node =
      tree.roots
      |> hd()
      |> Map.fetch!(:children)
      |> hd()
      |> Map.fetch!(:children)
      |> hd()

    assert c2_node.id == c2.id
    assert c2_node.truncated == :budget
    assert c2_node.children == []

    # Positive control: a bigger budget loads the whole chain.
    full = build_tree(scope, max_nodes: 100)
    assert full.node_count == 4
    refute full.truncated?
  end

  # -- ORG-SCOPE AT EVERY LEVEL (sabotage-refutable) ---------------------------

  test "ORG-SCOPE AT EVERY LEVEL: an org-B child pointing at org A's root NEVER appears in org A's tree" do
    mount = build_mount(:work)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    scope_a = Mount.scope(mount, org_a)
    scope_b = Mount.scope(mount, org_b)

    root_a = seed_task(org_a, "ROOT-A")
    child_a = seed_task(org_a, "CHILD-A", parent_id: root_a.id)

    root_b = seed_task(org_b, "ROOT-B")
    child_b = seed_task(org_b, "CHILD-B", parent_id: root_b.id)

    # SABOTAGE SEED: an org-B node whose parent_id points AT org A's root (forced past SameOrgFk).
    x_b = seed_task(org_b, "X-B")
    force_parent!(x_b.id, root_a.id)

    # Org A's tree: every level org-scoped → root A's children are org A's only; X-B is absent.
    tree_a = build_tree(scope_a, root: nil)
    all_a = flatten(tree_a.roots)

    assert node_ids(tree_a.roots) == [root_a.id]
    root_a_node = hd(tree_a.roots)
    assert node_ids(root_a_node.children) == [child_a.id]
    refute x_b.id in Enum.map(all_a, & &1.id)
    refute root_b.id in Enum.map(all_a, & &1.id)
    refute child_b.id in Enum.map(all_a, & &1.id)

    # REFUTATION: the SAME structural pointer resolves to X-B under org B's OWN scope (focused on
    # root A's id) — proving the seed is REAL and org-scope is what hides it from org A, not a
    # dead read.
    tree_b = build_tree(scope_b, root: root_a.id)
    assert x_b.id in node_ids(tree_b.roots)
  end

  defp flatten(nodes) do
    Enum.flat_map(nodes, fn n -> [n | flatten(n.children)] end)
  end

  # -- MASKING (INV-1) ---------------------------------------------------------

  test "MASKING: a VAULTED parent field is REFUSED, anchored against a real vaulted sibling" do
    mount = build_mount(:crm)
    scope = Mount.scope(mount, Ash.UUID.generate())

    err =
      assert_raise MaskedGroupKeyError, fn ->
        Mount.resource(mount, Person) |> Reads.tree!(:full_name, scope: scope)
      end

    assert err.message =~ "vault-routed"
    # The refusal is a live discriminator: :full_name really is vaulted; :parent_id is not.
    assert Samen.Pii.Info.vault_routed?(@person, :full_name)
    refute Samen.Pii.Info.vault_routed?(@task, :parent_id)
    refute Samen.Pii.Info.vault_routed?(@task, :title)
    refute Samen.Pii.Info.vault_routed?(@task, :status)
  end

  test "GREEN CONTROL: a non-vaulted parent field builds a %Tree{} (anti-tautology for the refusal)" do
    mount = build_mount(:work)
    scope = Mount.scope(mount, Ash.UUID.generate())
    assert %Tree{} = build_tree(scope, [])
  end
end
