defmodule Samen.WorkScopeTest do
  @moduledoc """
  The Work scope (F1, ADR-041 §3, T43) — Project + the canonical self-referential
  Task tree, mounted via `test/support/work_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  `Samen.RedPath` / masking-watch-list house style — CLAUDE.md):

    * c1 CRUD via governed actions + org-scoped reads (cross-org RED / own-org
      CONTROL, mirrors `Samen.RedPath.policy_matrix`'s shape without requiring a
      real `Identity.Org` resource — this fixture uses a bare `org_id` UUID,
      exactly like `Samen.SoftDeleteTest`);
    * c2 the Subtask tree: a legal N-level tree is accepted (CONTROL) and a cycle
      (self-parent + a deeper 3-node cycle) is refused (RED), plus a legal
      re-parent still succeeds (a second CONTROL proving the guard is not a
      blanket refusal);
    * c3 status/priority/due/owner filters, including `Samen.Type.Priority`'s
      ordered-rank sort (`low < normal < high < urgent`, ADR-036 D2);
    * c4 the Task schema matches ADR-041 §3.2 field-for-field (the schema-vs-ADR
      assert this file is required to carry);
    * c5 archive/restore (ADR-040 §5.9): Project and Task both hide-on-archive /
        show-via-:archived / return-on-restore; Task→Subtask cascades ARCHIVE
        (`archive_related`) and RESTORE (`Samen.Scopes.Work.CascadeRestore`) to the
        whole subtree at the same instant; Project→Task does NOT cascade;
    * c6 INV-1 — the Work scope's catalog PII map is EMPTY (no vaulted column) —
      the either-way no-PII declaration proof;
    * c7 cross-org FK refusal on `parent_id`/`project_id` (`Samen.Policy.SameOrgFk`)
      — RED cross-org / CONTROL same-org;
    * c8 catalog registration — `mix samen.verify.catalog_parity` is green (the
      migration's `catalog_sync/1` wrote matching `fld_field`/`tam_table` rows).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Archival
  alias SamenCore.Support.WorkFixture.{Project, Task}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp new_project(scope, org, attrs \\ %{}) do
    Project
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, name: "Proj"}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_task(scope, org, attrs \\ %{}) do
    Task
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, title: "T"}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp task_ids(scope) do
    Task |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()
  end

  defp archived_tasks(scope) do
    Task |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)
  end

  defp archived_task_ids(scope), do: archived_tasks(scope) |> Enum.map(& &1.id) |> MapSet.new()

  # ── c1: CRUD via governed actions + org-scoped reads ─────────────────────────

  describe "c1 — CRUD via governed actions; org-scoped reads" do
    test "create/read/update/destroy(=archive) a Project", %{org: org, scope: scope} do
      p = new_project(scope, org, %{name: "Launch"})
      assert p.status == :active

      [read] = Project |> Ash.read!(scope: scope)
      assert read.id == p.id

      updated =
        p
        |> Ash.Changeset.for_update(:update, %{status: :on_hold}, scope: scope)
        |> Ash.update!()

      assert updated.status == :on_hold

      :ok = Ash.destroy!(p, scope: scope)
      assert Project |> Ash.read!(scope: scope) == []
    end

    test "create/read/update/destroy(=archive) a Task", %{org: org, scope: scope} do
      t = new_task(scope, org, %{title: "Follow up"})
      assert t.status == :pending
      assert t.kind == :task

      [read] = Task |> Ash.read!(scope: scope)
      assert read.id == t.id

      updated =
        t
        |> Ash.Changeset.for_update(:update, %{status: :completed}, scope: scope)
        |> Ash.update!()

      assert updated.status == :completed

      :ok = Ash.destroy!(t, scope: scope)
      refute MapSet.member?(task_ids(scope), t.id)
    end

    test "an actor never reads another org's Tasks (RED); reads its own org's (CONTROL)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      task_a = new_task(scope_a, org_a, %{title: "A"})
      _task_b = new_task(scope_b, org_b, %{title: "B"})

      seen = Task |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)

      # CONTROL: sees its own org's row.
      assert task_a.id in seen
      # RED: never sees the foreign org's row.
      assert length(seen) == 1
    end

    test "an org-less actor sees zero Tasks (fail closed)", %{org: org, scope: scope} do
      _t = new_task(scope, org, %{title: "hidden"})

      orgless = %Samen.Scope{actor: %{id: "nobody", org_id: nil, role: :member}}

      case Ash.read(Task, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end
    end
  end

  # ── c2: the Subtask tree — cycle refusal ──────────────────────────────────────

  describe "c2 — Subtask tree: legal tree accepted, cycle refused (anti-tautology)" do
    test "a legal 3-level tree is accepted (CONTROL)", %{org: org, scope: scope} do
      root = new_task(scope, org, %{title: "root"})
      child = new_task(scope, org, %{title: "child", parent_id: root.id})
      grandchild = new_task(scope, org, %{title: "grandchild", parent_id: child.id})

      assert child.parent_id == root.id
      assert grandchild.parent_id == child.id

      loaded_root = Task |> Ash.Query.filter(id == ^root.id) |> Ash.read_one!(scope: scope)
      assert loaded_root.id == root.id
    end

    test "a task cannot be re-parented to become its own parent (self-cycle, RED)",
         %{org: org, scope: scope} do
      t = new_task(scope, org, %{title: "self"})

      result =
        t
        |> Ash.Changeset.for_update(:update, %{parent_id: t.id}, scope: scope)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "a deeper cycle (A -> B -> C, then C re-parented under A) is refused (RED)",
         %{org: org, scope: scope} do
      a = new_task(scope, org, %{title: "A"})
      b = new_task(scope, org, %{title: "B", parent_id: a.id})
      c = new_task(scope, org, %{title: "C", parent_id: b.id})

      # C is a descendant of A. Re-parenting A under C would make A its own
      # descendant's descendant — a cycle. Refused.
      result =
        a
        |> Ash.Changeset.for_update(:update, %{parent_id: c.id}, scope: scope)
        |> Ash.update()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "a LEGAL re-parent (not a cycle) still succeeds (second CONTROL — not a blanket refusal)",
         %{org: org, scope: scope} do
      old_parent = new_task(scope, org, %{title: "old"})
      new_parent = new_task(scope, org, %{title: "new"})
      child = new_task(scope, org, %{title: "child", parent_id: old_parent.id})

      updated =
        child
        |> Ash.Changeset.for_update(:update, %{parent_id: new_parent.id}, scope: scope)
        |> Ash.update!()

      assert updated.parent_id == new_parent.id
    end

    test "detaching a parent (parent_id -> nil) is always a no-op success", %{
      org: org,
      scope: scope
    } do
      parent = new_task(scope, org, %{title: "p"})
      child = new_task(scope, org, %{title: "c", parent_id: parent.id})

      updated =
        child
        |> Ash.Changeset.for_update(:update, %{parent_id: nil}, scope: scope)
        |> Ash.update!()

      assert is_nil(updated.parent_id)
    end
  end

  # ── c3: status/priority/due/owner filters ─────────────────────────────────────

  describe "c3 — status/priority/due/owner filters" do
    test "filtering by status returns only matching rows", %{org: org, scope: scope} do
      _pending = new_task(scope, org, %{title: "p", status: :pending})
      done = new_task(scope, org, %{title: "d", status: :completed})

      seen =
        Task
        |> Ash.Query.filter(status == :completed)
        |> Ash.read!(scope: scope)

      assert Enum.map(seen, & &1.id) == [done.id]
    end

    test "filtering by owner_id returns only matching rows", %{org: org, scope: scope} do
      owner = Ash.UUID.generate()
      mine = new_task(scope, org, %{title: "mine", owner_id: owner})
      _other = new_task(scope, org, %{title: "other"})

      seen = Task |> Ash.Query.filter(owner_id == ^owner) |> Ash.read!(scope: scope)
      assert Enum.map(seen, & &1.id) == [mine.id]
    end

    test "filtering by due_at (before a cutoff) returns only matching rows", %{
      org: org,
      scope: scope
    } do
      now = DateTime.utc_now()
      soon = DateTime.add(now, 3600, :second)
      later = DateTime.add(now, 3 * 86_400, :second)

      urgent = new_task(scope, org, %{title: "soon", due_at: soon})
      _later_task = new_task(scope, org, %{title: "later", due_at: later})

      cutoff = DateTime.add(now, 86_400, :second)

      seen =
        Task
        |> Ash.Query.filter(due_at <= ^cutoff)
        |> Ash.read!(scope: scope)

      assert Enum.map(seen, & &1.id) == [urgent.id]
    end

    test "priority uses Samen.Type.Priority — ordered, sortable low < normal < high < urgent",
         %{org: org, scope: scope} do
      assert {:attribute, %{type: Samen.Type.Priority}} =
               {:attribute, Ash.Resource.Info.attribute(Task, :priority)}

      _u = new_task(scope, org, %{title: "u", priority: :urgent})
      _l = new_task(scope, org, %{title: "l", priority: :low})
      _h = new_task(scope, org, %{title: "h", priority: :high})
      _n = new_task(scope, org, %{title: "n", priority: :normal})

      ascending =
        Task
        |> Ash.Query.sort(priority: :asc)
        |> Ash.read!(scope: scope)
        |> Enum.map(& &1.priority)

      assert ascending == [:low, :normal, :high, :urgent]

      # Filtering by priority is a normal enum-equality filter (the atom face).
      only_high = Task |> Ash.Query.filter(priority == :high) |> Ash.read!(scope: scope)
      assert Enum.map(only_high, & &1.priority) == [:high]
    end

    test "priority defaults to :normal when omitted", %{org: org, scope: scope} do
      t = new_task(scope, org, %{title: "default-priority"})
      assert t.priority == :normal
    end
  end

  # ── c4: the Task schema matches ADR-041 §3.2 field-for-field ──────────────────

  describe "c4 — Task schema matches ADR-041 §3.2 (schema-vs-ADR assert)" do
    test "every ADR-041 §3.2 attribute is present with the specified type/default" do
      attrs = Ash.Resource.Info.attributes(Task) |> Map.new(&{&1.name, &1})

      assert attrs.kind.type == Ash.Type.Atom
      assert attrs.title.type == Ash.Type.String
      assert attrs.body.type == Ash.Type.String

      assert attrs.status.type == Ash.Type.Atom
      assert Enum.sort(attrs.status.constraints[:one_of]) ==
               Enum.sort([:pending, :in_progress, :completed, :cancelled])

      assert attrs.priority.type == Samen.Type.Priority

      assert attrs.due_at.type == Ash.Type.UtcDatetime
      assert attrs.completed_at.type == Ash.Type.UtcDatetime

      assert attrs.subject_key.type == Ash.Type.String
      assert attrs.subject_id.type == Ash.Type.UUID

      assert attrs.custom.type == Ash.Type.Map
      assert attrs.owner_id.type == Ash.Type.UUID

      # parent_id / project_id are injected by the belongs_to relationships.
      assert attrs.parent_id.type == Ash.Type.UUID
      assert attrs.project_id.type == Ash.Type.UUID

      # Base-macro universal columns (ADR-041 §3.2 closing note).
      assert Map.has_key?(attrs, :id)
      assert Map.has_key?(attrs, :org_id)
      assert Map.has_key?(attrs, :inserted_at)
      assert Map.has_key?(attrs, :updated_at)
      # ADR-040 §5.9 — archivable true.
      assert Map.has_key?(attrs, :archived_at)
    end

    test "Task.kind carries the exact Activity-parity enum" do
      kind = Ash.Resource.Info.attribute(Task, :kind)
      assert Enum.sort(kind.constraints[:one_of]) ==
               Enum.sort([:task, :call, :email, :meeting, :note])
    end

    test "the self-referential Subtask tree is realized as Task.parent_id, no third resource" do
      rels = Ash.Resource.Info.relationships(Task) |> Map.new(&{&1.name, &1})
      assert rels.parent.type == :belongs_to
      assert rels.parent.destination == Task
      assert rels.subtasks.type == :has_many
      assert rels.subtasks.destination == Task
      assert rels.project.type == :belongs_to
      assert rels.project.destination == Project
    end

    test "defaults behaviorally match ADR-041 §3.2 (kind :task, status :pending, priority :normal)",
         %{org: org, scope: scope} do
      t = new_task(scope, org)
      assert t.kind == :task
      assert t.status == :pending
      assert t.priority == :normal
      assert is_nil(t.due_at)
      assert is_nil(t.completed_at)
      assert is_nil(t.subject_key)
      assert is_nil(t.subject_id)
      assert is_nil(t.owner_id)
      assert is_nil(t.parent_id)
      assert is_nil(t.project_id)
    end
  end

  # ── c5: archive/restore + cascade ─────────────────────────────────────────────

  describe "c5 — archive/restore (ADR-040 §5.9); Task->Subtask cascades both ways" do
    test "Project archive hides it (RED), :archived shows it (CONTROL), restore returns it",
         %{org: org, scope: scope} do
      p = new_project(scope, org)
      {:ok, _} = Archival.archive(p, scope: scope)
      assert Project |> Ash.read!(scope: scope) == []

      archived = Project |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)
      assert Enum.map(archived, & &1.id) == [p.id]

      {:ok, _} = Archival.restore(hd(archived), scope: scope)
      assert Enum.map(Project |> Ash.read!(scope: scope), & &1.id) == [p.id]
    end

    test "Task archive hides it (RED), :archived shows it (CONTROL), restore returns it",
         %{org: org, scope: scope} do
      t = new_task(scope, org)
      {:ok, _} = Archival.archive(t, scope: scope)
      refute MapSet.member?(task_ids(scope), t.id)
      assert MapSet.member?(archived_task_ids(scope), t.id)

      restored = archived_tasks(scope) |> hd()
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(task_ids(scope), t.id)
    end

    test "archiving a parent Task cascades to archive its whole Subtask subtree at once",
         %{org: org, scope: scope} do
      root = new_task(scope, org, %{title: "root"})
      child = new_task(scope, org, %{title: "child", parent_id: root.id})
      grandchild = new_task(scope, org, %{title: "grandchild", parent_id: child.id})
      unrelated = new_task(scope, org, %{title: "unrelated"})

      {:ok, _} = Archival.archive(root, scope: scope)

      live = task_ids(scope)
      # RED: the whole subtree (root, child, grandchild) is gone from default reads.
      refute MapSet.member?(live, root.id)
      refute MapSet.member?(live, child.id)
      refute MapSet.member?(live, grandchild.id)
      # CONTROL: an unrelated task (not in the subtree) is untouched.
      assert MapSet.member?(live, unrelated.id)

      archived = archived_task_ids(scope)
      assert MapSet.member?(archived, root.id)
      assert MapSet.member?(archived, child.id)
      assert MapSet.member?(archived, grandchild.id)
    end

    test "restoring the parent Task cascades to restore its whole Subtask subtree at once",
         %{org: org, scope: scope} do
      root = new_task(scope, org, %{title: "root"})
      child = new_task(scope, org, %{title: "child", parent_id: root.id})
      grandchild = new_task(scope, org, %{title: "grandchild", parent_id: child.id})

      {:ok, _} = Archival.archive(root, scope: scope)
      refute MapSet.member?(task_ids(scope), root.id)

      restored_root = archived_tasks(scope) |> Enum.find(&(&1.id == root.id))
      {:ok, _} = Archival.restore(restored_root, scope: scope)

      live = task_ids(scope)
      assert MapSet.member?(live, root.id)
      assert MapSet.member?(live, child.id)
      assert MapSet.member?(live, grandchild.id)
      assert archived_task_ids(scope) == MapSet.new()
    end

    test "archiving a Project does NOT cascade to its Tasks (no-cascade, ADR-041 §3.5)",
         %{org: org, scope: scope} do
      p = new_project(scope, org)
      t = new_task(scope, org, %{title: "survivor", project_id: p.id})

      {:ok, _} = Archival.archive(p, scope: scope)

      # CONTROL: the task outlives its project's archival — still in default reads.
      assert MapSet.member?(task_ids(scope), t.id)
    end
  end

  # ── c6: INV-1 — the Work scope's catalog PII map is EMPTY ─────────────────────

  describe "c6 — INV-1: no-PII declaration (the Work scope vaults nothing)" do
    test "Project carries zero pii_attribute fields" do
      assert Samen.Pii.Info.fields(Project) == []
    end

    test "Task carries zero pii_attribute fields" do
      assert Samen.Pii.Info.fields(Task) == []
    end
  end

  # ── c7: cross-org FK refusal on parent_id / project_id ─────────────────────────

  describe "c7 — SameOrgFk refuses a cross-org parent/project FK (RED), same-org succeeds (CONTROL)" do
    test "a Task cannot set project_id to a DIFFERENT org's Project (RED)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      foreign_project = new_project(scope_b, org_b)

      result =
        Task
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_a, title: "cross-org", project_id: foreign_project.id},
          scope: scope_a
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
    end

    test "a Task CAN set project_id to its OWN org's Project (CONTROL)", %{
      org: org,
      scope: scope
    } do
      p = new_project(scope, org)

      t =
        Task
        |> Ash.Changeset.for_create(:create, %{org_id: org, title: "same-org", project_id: p.id},
          scope: scope
        )
        |> Ash.create!()

      assert t.project_id == p.id
    end

    test "a Task cannot set parent_id to a DIFFERENT org's Task (RED)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      foreign_task = new_task(scope_b, org_b, %{title: "foreign"})

      result =
        Task
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_a, title: "cross-org-child", parent_id: foreign_task.id},
          scope: scope_a
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
    end
  end

  # ── c8: catalog registration ────────────────────────────────────────────────

  describe "c8 — catalog registration (mix samen.verify.catalog_parity is green)" do
    test "the Work fixture's tables/columns are fully catalogued (no violations)" do
      violations =
        Mix.Tasks.Samen.Verify.CatalogParity.check(@repo)
        |> Enum.filter(&(&1 =~ "spw_project" or &1 =~ "stw_task"))

      assert violations == [],
             "expected no catalog_parity violations for the Work fixture tables, got: " <>
               inspect(violations)
    end
  end
end
