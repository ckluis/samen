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
  alias Samen.Web.Reads.Guard

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
    Guard.page(:work_tasks_page, scope, state, fn ->
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
    end)
  end

  @doc """
  Build the Work Task TIMELINE / Gantt board (T53, G3 — the FIRST client of the generic
  `Samen.Web.Reads.timeline_window!/3`). Positions Tasks as horizontal BARS by their
  `:inserted_at`..`:due_at` range, grouped into STATUS lanes (the bounded `task_statuses/0`
  enum), for rendering through `Samen.UI.gantt/1`.

  This is the THIN vertical wiring: it names the resource (`Task`), the axis fields
  (start `:inserted_at`, end `:due_at`), the lane facet (`:status`), and the window, then
  delegates ALL windowing (the overlap filter), per-lane bounding, exact counts, org-scoping,
  and the vault-field refusal to `timeline_window!/3` — it re-implements none of that. Tasks are
  NON-PII (no vault field), so no PII resolution is needed; the board never plaintext-downgrades.

  A Task with a NULL `:due_at` (no deadline) is a POINT bar at its `:inserted_at` — never an
  infinite bar (handled by `timeline_window!/3`). `range` is a `{start, end_exclusive}` DateTime
  window. On any read error the board is EMPTY (`groups: []`), never an unbounded read.

  `opts`:

    * `:per_group_limit` — per-lane bar cap forwarded to `timeline_window!/3`.
  """
  def tasks_timeline(mount, scope, {_s, _e} = range, opts \\ []) do
    tasks_timeline_result(mount, scope, range, opts)
    |> Guard.value(%{board: %Samen.Web.Board{groups: [], group_field: :status}, range: range})
  end

  @doc """
  Tagged sibling of `tasks_timeline/4` (WP6): `{:ok, %{board:, range:}}`, or
  `{:error, :unavailable | :forbidden}` — a failed board read is not an empty board.
  """
  def tasks_timeline_result(mount, scope, {_s, _e} = range, opts \\ []) do
    Guard.run(:work_tasks_timeline, scope, fn ->
      cap = Keyword.get(opts, :per_group_limit, Samen.Web.Reads.default_timeline_cap())

      lanes = Enum.map(@task_statuses, fn s -> {s, status_label(s)} end)

      board =
        Mount.resource(mount, Task)
        |> Ash.Query.ensure_selected([:title, :status, :priority, :due_at, :completed_at, :project_id, :inserted_at])
        |> Samen.Web.Reads.timeline_window!(:inserted_at,
          scope: scope,
          end_field: :due_at,
          lane_field: :status,
          groups: lanes,
          range: range,
          per_group_limit: cap,
          row_sort: {:inserted_at, :asc}
        )

      %{board: board, range: range}
    end)
  end

  defp status_label(:pending), do: "Pending"
  defp status_label(:in_progress), do: "In progress"
  defp status_label(:completed), do: "Completed"
  defp status_label(:cancelled), do: "Cancelled"
  defp status_label(other), do: to_string(other)

  @doc """
  Build the Work Task TREE (T54, G6 — the FIRST client of the generic `Samen.Web.Reads.tree!/3`).
  Walks the self-referential `Task.:parent_id` (the `belongs_to :parent` pointer, ADR-041 §3.4)
  into a DEPTH-BOUNDED, CYCLE-SAFE, per-parent-BOUNDED `%Samen.Web.Tree{}` for rendering through
  `Samen.UI.tree/1`.

  This is the THIN vertical wiring: it names the resource (`Task`) and the parent facet
  (`:parent_id`), then delegates ALL depth-bounding, cycle-safety, per-parent bounding, exact
  child counts, org-scoping-AT-EVERY-LEVEL, and the vault-field refusal to `tree!/3` — it
  re-implements none of that. Tasks are NON-PII (no vault field on a node), so no PII resolution
  is needed; the tree never plaintext-downgrades regardless.

  `root` is the drill-in focus node id (`nil` = the TRUE roots — tasks with no parent). On any
  read error the tree is EMPTY (`roots: []`), never an unbounded read.

  `opts` are forwarded to `tree!/3` (`:sibling_limit`, `:max_depth`, `:max_nodes`, `:row_sort`).
  """
  def tasks_tree(mount, scope, root \\ nil, opts \\ []) do
    tasks_tree_result(mount, scope, root, opts)
    |> Guard.value(%{tree: %Samen.Web.Tree{roots: [], parent_field: :parent_id}, root: root})
  end

  @doc """
  Tagged sibling of `tasks_tree/4` (WP6): `{:ok, %{tree:, root:}}`, or
  `{:error, :unavailable | :forbidden}` — a failed walk is not "No tasks".
  """
  def tasks_tree_result(mount, scope, root \\ nil, opts \\ []) do
    Guard.run(:work_tasks_tree, scope, fn ->
      tree =
        Mount.resource(mount, Task)
        |> Ash.Query.ensure_selected([:title, :status, :priority, :parent_id, :project_id])
        |> Samen.Web.Reads.tree!(
          :parent_id,
          [scope: scope, root: root, row_sort: {:inserted_at, :asc}] ++ opts
        )

      %{tree: tree, root: root}
    end)
  end

  @doc "Read a single Task by id for `scope`. `{:ok, task}` or `:error`."
  def get_task(mount, scope, id) do
    case get_task_result(mount, scope, id) do
      {:ok, task} -> {:ok, task}
      {:error, _} -> :error
    end
  end

  @doc """
  Tagged sibling of `get_task/3` (WP6): `{:ok, task}`, `{:error, :not_found}` for a missing,
  malformed-id or denied record, and `{:error, :unavailable}` ONLY when the read FAILED — a
  failed read is not "Task not found."
  """
  def get_task_result(mount, scope, id) do
    single_result(:work_get_task, scope, id, fn uuid ->
      Mount.resource(mount, Task)
      |> Ash.Query.filter(id == ^uuid)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc "Read the direct Subtasks (children) of `task_id` for `scope`. BOUNDED."
  def subtasks(mount, scope, task_id), do: subtasks_result(mount, scope, task_id) |> Guard.value([])

  @doc "Tagged sibling of `subtasks/3` (WP6): `{:ok, rows}` or `{:error, :unavailable | :forbidden}`."
  def subtasks_result(mount, scope, task_id) do
    Guard.run(:work_subtasks, scope, fn ->
      Mount.resource(mount, Task)
      |> Ash.Query.filter(parent_id == ^task_id)
      |> Ash.Query.ensure_selected([:title, :status, :priority, :due_at])
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc "Read Projects for `scope`, newest-first. BOUNDED. No PII."
  def projects(mount, scope), do: projects_result(mount, scope) |> Guard.value([])

  @doc "Tagged sibling of `projects/2` (WP6): `{:ok, rows}` or `{:error, :unavailable | :forbidden}`."
  def projects_result(mount, scope) do
    Guard.run(:work_projects, scope, fn ->
      Mount.resource(mount, Project)
      |> Ash.Query.ensure_selected([:name, :status, :owner_id])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@detail_limit)
      |> Ash.read!(scope: scope)
    end)
  end

  @doc "Read a single Project by id for `scope`. `{:ok, project}` or `:error`."
  def get_project(mount, scope, id) do
    case get_project_result(mount, scope, id) do
      {:ok, project} -> {:ok, project}
      {:error, _} -> :error
    end
  end

  @doc "Tagged sibling of `get_project/3` (WP6); same contract as `get_task_result/3`."
  def get_project_result(mount, scope, id) do
    single_result(:work_get_project, scope, id, fn uuid ->
      Mount.resource(mount, Project)
      |> Ash.Query.filter(id == ^uuid)
      |> Ash.Query.limit(1)
      |> Ash.read!(scope: scope)
    end)
  end

  # One record by id: a malformed id is a plain not-found (no read is attempted), an empty
  # result is not-found, a denial is not-found (no existence oracle), and only a FAILED read is
  # `:unavailable`. `read` returns the (<= 1 row) list.
  defp single_result(key, scope, id, read) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, rows} <- Guard.run(key, scope, fn -> read.(uuid) end) do
      case rows do
        [record | _] -> {:ok, record}
        [] -> {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
      {:error, :forbidden} -> {:error, :not_found}
      {:error, :unavailable} = unavailable -> unavailable
    end
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
