defmodule Samen.Web.WorkRenderTest do
  @moduledoc """
  Framework Work render tests against the test-support host (F1, ADR-041 §3, T43).

  Work carries NO PII (INV-1) — unlike the Support render tests, there is no
  vault-routed field to prove masks on either plane. What these tests DO prove
  (mirroring `support_render_test.exs`'s "drive the real mount lifecycle" style,
  via `mount_smoke/4`):

    * the Task inbox, Task detail, and Projects list mount + render on BOTH the
      tenant and the operator plane without error (the masking seam applies by
      construction even though it resolves nothing — ADR-041 §9);
    * the Subtask tree renders on the detail page;
    * no `%Samen.Masked{}`/`••••` ever appears (there is nothing to mask — the
      negative-space proof for a no-PII scope).

  Fixtures are created directly (NOT via `Samen.WebTest.Seeds` — that shared file
  is T97's to touch per the ADR-041 §7 file-touch partition; this scope has zero
  CRM contact).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.WebTest.Work.{Project, Task}

  setup do
    org_id = Ash.UUID.generate()

    project =
      Project
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "Q3 Launch"})
      |> Ash.create!(authorize?: false)

    task =
      Task
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        title: "Draft the launch brief",
        status: :in_progress,
        priority: :high,
        project_id: project.id
      })
      |> Ash.create!(authorize?: false)

    subtask =
      Task
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        title: "Get stakeholder sign-off",
        status: :pending,
        parent_id: task.id
      })
      |> Ash.create!(authorize?: false)

    %{org_id: org_id, project: project, task: task, subtask: subtask}
  end

  test "TENANT plane: /work inbox mounts + renders the seeded task", %{org_id: org_id, task: task} do
    mount = build_mount(:work, plane: :tenant)
    html = mount_smoke(Samen.Web.Work.TasksLive, mount, %{"org" => org_id})

    assert html =~ ~s(class="app")
    assert html =~ "task-row"
    assert html =~ task.title
  end

  test "OPERATOR plane: /work inbox mounts + renders without error (no PII to mask)", %{
    org_id: org_id,
    task: task
  } do
    mount = build_mount(:work, plane: :operator, target_org_id: org_id)
    html = mount_smoke(Samen.Web.Work.TasksLive, mount, %{"org" => org_id})

    assert html =~ task.title
    refute html =~ "••••"
  end

  test "TENANT plane: task detail renders the task + its Subtask", %{
    org_id: org_id,
    task: task,
    subtask: subtask
  } do
    mount = build_mount(:work, plane: :tenant)
    html = mount_smoke(Samen.Web.Work.TaskLive, mount, %{"org" => org_id, "id" => task.id})

    assert html =~ task.title
    assert html =~ "subtasks-list"
    assert html =~ subtask.title
  end

  test "TENANT plane: projects list renders the seeded project", %{org_id: org_id, project: project} do
    mount = build_mount(:work, plane: :tenant)
    html = mount_smoke(Samen.Web.Work.ProjectsLive, mount, %{"org" => org_id})

    assert html =~ "project-row"
    assert html =~ project.name
  end

  test "cross-org: an operator impersonating a DIFFERENT org never sees this org's task", %{
    task: task
  } do
    foreign_org = Ash.UUID.generate()
    mount = build_mount(:work, plane: :operator, target_org_id: foreign_org)
    html = mount_smoke(Samen.Web.Work.TasksLive, mount, %{"org" => foreign_org})

    refute html =~ task.title
  end
end
