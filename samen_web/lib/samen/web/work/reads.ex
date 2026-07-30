defmodule Samen.Web.Work.Reads do
  @moduledoc """
  The framework Work read layer for the inherited Work pages (task list/detail,
  project list). Resource + repo come from `Samen.Web.Mount` (ADR-009 §3.3).

  ## No PII (INV-1)

  The Work scope carries zero vault-routed fields (`Samen.Scopes.Work` moduledoc;
  ADR-041 §10) — this module never calls `Samen.Api.PiiResolution.resolve/4`
  because there is nothing to resolve. `title`/`body`/`custom` are freeform,
  unvaulted, default-deny-CDC-excluded (Activity parity).

  ## A3 read-bounding

  The Task Inbox reads through the paginated `tasks_page/3` (built on
  `Samen.Web.Reads.page!/3` — BOUNDED BY CONSTRUCTION); every remaining detail
  read carries an explicit `limit(#{200})`.

  ## A3 write side (sanctioned domain actions only)

  The Work blueprint defines `defaults([:read, :destroy, create: :*, update: :*])`;
  this module only exposes those.
  """

  require Ash.Query

  alias Samen.Web.Mount

  @detail_limit 200

  # The blueprint's bounded status enum — client input is matched against THIS
  # list, never atomized (`String.to_atom/1` on client input mints atoms).
  @task_statuses [:pending, :in_progress, :completed, :cancelled]

  @doc "The bounded task status set (the blueprint's `one_of` — the status select's options)."
  def task_statuses, do: @task_statuses

  @doc """
  Read ONE keyset page of Tasks for `scope` — the `ListLive` reads contract
  (`(mount, scope, %ListState{}) -> %Page{}`, ADR-016 §3), built on
  `Samen.Web.Reads.page!/3` so the read is BOUNDED BY CONSTRUCTION. `title` is
  freeform (not vaulted, default-deny-CDC-excluded). On any read error the page
  is EMPTY — never unbounded.
  """
  def tasks_page(mount, scope, state) do
    Mount.resource(mount, Task)
    |> Ash.Query.ensure_selected([
      :kind,
      :title,
      :status,
      :priority,
      :due_at,
      :completed_at,
      :owner_id,
      :parent_id,
      :project_id
    ])
    |> Samen.Web.Reads.page!(state, scope: scope, filter_fields: [:title])
  rescue
    _ -> %Samen.Web.Page{items: [], page_size: Samen.Web.Reads.bounded_page_size(state.page_size)}
  end

  @doc "Read a single Task by id for `scope`. `{:ok, task}` or `:error`."
  def get_task(mount, scope, id) do
    result =
      Mount.resource(mount, Task)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)

    case result do
      [task | _] -> {:ok, task}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Read the direct Subtasks (children) of `task_id` for `scope`. BOUNDED."
  def subtasks(mount, scope, task_id) do
    Mount.resource(mount, Task)
    |> Ash.Query.filter(parent_id == ^task_id)
    |> Ash.Query.ensure_selected([:title, :status, :priority, :due_at])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read Projects for `scope`, newest-first. BOUNDED. No PII."
  def projects(mount, scope) do
    Mount.resource(mount, Project)
    |> Ash.Query.ensure_selected([:name, :status, :owner_id])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(@detail_limit)
    |> Ash.read!(scope: scope)
  rescue
    _ -> []
  end

  @doc "Read a single Project by id for `scope`. `{:ok, project}` or `:error`."
  def get_project(mount, scope, id) do
    result =
      Mount.resource(mount, Project)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)

    case result do
      [project | _] -> {:ok, project}
      [] -> :error
    end
  rescue
    _ -> :error
  end

  # -- A3 write side (sanctioned defaults only) --------------------------------

  @doc """
  Update a task's STATUS (the sanctioned `update: :*`). `status` is a STRING
  matched against the bounded blueprint enum (`task_statuses/0`) — client input
  never mints an atom; an unknown status is refused as `{:error, :invalid_status}`.
  """
  def update_task_status(mount, scope, id, status) when is_binary(status) do
    case Enum.find(@task_statuses, fn s -> Atom.to_string(s) == status end) do
      nil -> {:error, :invalid_status}
      bounded -> update_task_status(mount, scope, id, bounded)
    end
  end

  def update_task_status(mount, scope, id, status) when status in @task_statuses do
    record =
      Mount.resource(mount, Task)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> {:error, :not_found}
      task -> task |> Ash.Changeset.for_update(:update, %{status: status}, scope: scope) |> Ash.update()
    end
  rescue
    e -> {:error, e}
  end

  @doc "Destroy (=archive, ADR-040 §5.9) one Task for `scope`. `:ok` or `{:error, reason}`."
  def delete_task(mount, scope, id) do
    record =
      Mount.resource(mount, Task)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> {:error, :not_found}
      task -> Ash.destroy(task, scope: scope)
    end
  rescue
    e -> {:error, e}
  end

  @doc "Destroy (=archive) one Project for `scope`. `:ok` or `{:error, reason}`."
  def delete_project(mount, scope, id) do
    record =
      Mount.resource(mount, Project)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(scope: scope)

    case record do
      nil -> {:error, :not_found}
      project -> Ash.destroy(project, scope: scope)
    end
  rescue
    e -> {:error, e}
  end
end
