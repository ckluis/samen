defmodule Samen.Web.ListLive do
  @moduledoc """
  The list-ergonomics MIXIN (ADR-016 §2, WS-A design §1.1) — `use` it in any mounted
  LiveView and the view inherits paginated/sorted/filtered/bulk-selectable reads with
  ≈0 vertical lines:

      use Samen.Web.ListLive,
        resource: Person,
        reads: &MyApp.Reads.contacts/3,
        sortable: [:display_name, :job_title],
        filter_fields: [:display_name]

  `restore` (ADR-040 §5.8, T37h) additionally accepts `:write_scope` — a 1-arity
  `(scope) -> scope` elevator, default identity. Most resources' writes are gated the
  SAME as their reads (CRM `Person`: `RoleAtLeast :member` — the plain list `scope`
  already qualifies); a resource with a STRICTER write gate (Billing `Plan`:
  `RoleAtLeast :admin`) passes its own elevator (e.g.
  `write_scope: &Samen.Web.Billing.Reads.elevate_to_admin/1`) — the SAME elevation its
  other hand-authored write events (`new_plan`/`toggle_plan`/`delete`) already apply.

      def load(socket, org_id) do
        socket |> assign(org_id: org_id) |> init_list(mount, scope)
      end

  `init_list/3` seeds a `%Samen.Web.ListState{}`, runs the FIRST bounded read, assigns
  `:list_state` + `:page`, and (on a real mounted socket) attaches a `:handle_event`
  lifecycle hook that owns the `list_view/1` events — so the view needs NO
  `handle_event/3` clauses of its own for sort/filter/paginate/select/bulk, and its
  own clauses (for other events) keep working untouched (the hook `:cont`s anything it
  does not own). This is the LiveView-sanctioned "delegated events" pattern; a
  `use`-injected `handle_event/3` clause set would collide with the view's own.

  ## The reads contract (the read is BOUNDED by construction)

  `reads` is a 3-arity function `(mount, scope, %ListState{}) -> %Samen.Web.Page{}`,
  conventionally built on `Samen.Web.Reads.page!/3` — which ALWAYS applies
  `limit(page_size + 1)` and clamps `page_size` to `Samen.Web.Reads.max_page_size/0`.
  A list that adopts this mixin therefore cannot re-introduce an unbounded `read!`:
  every event re-runs the SAME bounded read with mutated state.

  ## Events owned by the hook

    * `"sort"`       — `%{"field" => f}`; `f` must name a declared `:sortable` field
      (matched against the BOUNDED compile-time list — user input never mints an
      atom); toggles asc/desc, resets to the first page.
    * `"filter"`     — `%{"filter" => q}`; sets the filter box, resets to page one.
    * `"paginate"`   — `%{"dir" => "next" | "prev"}`; keyset next/prev via the
      server-side cursor stack (cursors never round-trip through the client).
    * `"select"`     — `%{"id" => id}`; toggles one row in the selection set.
    * `"select_all"` — toggles the CURRENT PAGE's rows in the selection set.
    * `"bulk"`       — `%{"action" => a}`; calls the view's `handle_bulk/3`
      (overridable; default no-op), then clears the selection and re-reads.
    * `"toggle_archived"` — no params; flips `%ListState{}.show_archived` (resets
      to the first page) and re-reads (ADR-040 §5.8, T37h). The caller's `reads/3`
      decides what the flag MEANS — conventionally a filter SWITCH (live rows when
      `false`, the `:archived` trash-only read when `true`; `Samen.Archival`'s
      `:archived` read is archived rows ONLY, not a union with the live set) — the
      mixin only carries the state, never issues an archived-aware query itself, so
      a `reads/3` that ignores the flag is unaffected (byte-identical to pre-T37h
      behavior).
    * `"restore"`    — `%{"id" => id}`; FAIL-HONEST: finds `id` among the CURRENT
      page's items and, only when `config.resource` is `Samen.Info.archivable?/1`,
      calls `Samen.Archival.restore/2` on it (scoped, never `authorize?: false`),
      then re-reads on success. A non-archivable resource, or an id not on the
      current page, is a no-op — never a crash (T37h; no per-vertical hand-wiring:
      any view riding this mixin inherits `restore` "for free" the moment its
      resource is archivable and its `reads/3` surfaces archived rows).

  ## Masking posture

  The mixin moves STATE and re-runs the caller's read. It never renders, stringifies,
  or inspects a field value, and never touches the vault — masking rides entirely on
  the read path (`PiiResolution` inside the caller's `reads`) and the render path
  (`%Samen.Masked{}` → `••••` via `Phoenix.HTML.Safe`).
  """

  alias Samen.Web.ListState
  alias Samen.Web.Reads

  @hook_id :samen_list_live
  @events ~w(sort filter paginate select select_all bulk toggle_archived restore)

  defmacro __using__(opts) do
    quote do
      @samen_list_opts unquote(opts)

      @doc false
      def __list_config__, do: Samen.Web.ListLive.build_config(@samen_list_opts)

      @doc """
      Seed the list state, run the first bounded read, and attach the list event hook.
      """
      def init_list(socket, mount, scope),
        do: Samen.Web.ListLive.init(socket, __MODULE__, mount, scope)

      @doc """
      Handle a `"bulk"` action over the selected row ids. Override in the view;
      the default is a no-op. Must return the socket.
      """
      def handle_bulk(_action, _ids, socket), do: socket

      defoverridable handle_bulk: 3
    end
  end

  @doc false
  def build_config(opts) do
    reads = Keyword.fetch!(opts, :reads)
    sortable = Keyword.get(opts, :sortable, [:id])

    %{
      resource: Keyword.get(opts, :resource),
      reads: reads,
      sortable: sortable,
      filter_fields: Keyword.get(opts, :filter_fields, []),
      default_sort: Keyword.get(opts, :default_sort, {hd(sortable), :asc}),
      page_size: Reads.bounded_page_size(Keyword.get(opts, :page_size, Reads.default_page_size())),
      # ADR-040 §5.8 (T37h) — `restore`'s write-scope elevator, default identity. ADR-045 §4.4
      # (S1a): now `(scope, socket) -> scope` so the elevator can re-derive the admin scope from
      # the socket's pinned principal (armed hosts derive the REAL membership role, never a
      # hardcoded `:admin`). See moduledoc.
      write_scope: Keyword.get(opts, :write_scope, fn scope, _socket -> scope end)
    }
  end

  @doc """
  Initialize list state on `socket` for `view` (a module that `use`d this mixin):
  assigns `:list_state` + `:page` (the first bounded read) + the private read context,
  and attaches the `:handle_event` hook on a real mounted socket. Idempotent — a
  `handle_params` re-entry re-reads but never double-attaches.
  """
  def init(socket, view, mount, scope) do
    config = view.__list_config__()

    state = %ListState{
      sort: config.default_sort,
      page_size: config.page_size
    }

    socket
    |> Phoenix.Component.assign(:samen_list_ctx, %{view: view, mount: mount, scope: scope})
    |> reread(state)
    |> maybe_attach_hook()
  end

  @doc """
  The `:handle_event` lifecycle hook: `{:halt, socket}` for the list events this mixin
  owns, `{:cont, socket}` for everything else (the view's own `handle_event/3` runs).
  """
  def on_event(event, params, socket) when event in @events do
    {:noreply, socket} = handle_list_event(event, params, socket)
    {:halt, socket}
  end

  def on_event(_event, _params, socket), do: {:cont, socket}

  @doc """
  Handle one list event — the hook target, also directly callable (and directly
  tested) on a harness-built socket. Returns `{:noreply, socket}`.
  """
  def handle_list_event("sort", %{"field" => field}, socket) do
    %{state: state, config: config} = list_assigns(socket)

    case bounded_field(config.sortable, field) do
      nil ->
        {:noreply, socket}

      sort_field ->
        state = %{state | sort: toggle_sort(state.sort, sort_field), cursor: nil, cursor_stack: []}
        {:noreply, reread(socket, state)}
    end
  end

  def handle_list_event("filter", params, socket) do
    %{state: state} = list_assigns(socket)
    filter = filter_param(params)
    socket = reread(socket, %{state | filter: filter, cursor: nil, cursor_stack: []})
    emit_search_used(socket, filter)
    {:noreply, socket}
  end

  def handle_list_event("paginate", %{"dir" => "next"}, socket) do
    %{state: state} = list_assigns(socket)
    page = socket.assigns.page

    if page.has_more and page.next_cursor != nil do
      state = %{
        state
        | cursor_stack: [state.cursor | state.cursor_stack],
          cursor: page.next_cursor
      }

      {:noreply, reread(socket, state)}
    else
      {:noreply, socket}
    end
  end

  def handle_list_event("paginate", %{"dir" => "prev"}, socket) do
    %{state: state} = list_assigns(socket)

    case state.cursor_stack do
      [] -> {:noreply, socket}
      [prev | rest] -> {:noreply, reread(socket, %{state | cursor: prev, cursor_stack: rest})}
    end
  end

  def handle_list_event("paginate", _params, socket), do: {:noreply, socket}

  def handle_list_event("select", %{"id" => id}, socket) do
    %{state: state} = list_assigns(socket)

    selected =
      if MapSet.member?(state.selected, id),
        do: MapSet.delete(state.selected, id),
        else: MapSet.put(state.selected, id)

    {:noreply, assign_state(socket, %{state | selected: selected})}
  end

  def handle_list_event("select_all", _params, socket) do
    %{state: state} = list_assigns(socket)
    page_ids = MapSet.new(socket.assigns.page.items, & &1.id)

    selected =
      if MapSet.subset?(page_ids, state.selected),
        do: MapSet.difference(state.selected, page_ids),
        else: MapSet.union(state.selected, page_ids)

    {:noreply, assign_state(socket, %{state | selected: selected})}
  end

  def handle_list_event("bulk", %{"action" => action}, socket) do
    %{state: state, view: view} = list_assigns(socket)

    socket = view.handle_bulk(action, MapSet.to_list(state.selected), socket)
    state = %{socket.assigns.list_state | selected: MapSet.new()}
    {:noreply, reread(socket, state)}
  end

  # ADR-040 §5.8 (T37h) — the archived-filter toggle. Resets to the first page (the
  # underlying result SET changes shape when archived rows join/leave it, so a stale
  # cursor from the other filter state would be meaningless).
  def handle_list_event("toggle_archived", _params, socket) do
    %{state: state} = list_assigns(socket)

    state = %{state | show_archived: not state.show_archived, cursor: nil, cursor_stack: []}
    {:noreply, reread(socket, state)}
  end

  # ADR-040 §5.8 (T37h) — FAIL-HONEST restore: only a resource that is actually
  # `Samen.Info.archivable?/1` is touched (a non-archivable resource's `restore` is a
  # structural no-op, never a crash — the same "the write only fires when it can
  # succeed" posture `handle_list_event/3`'s other clauses already carry). The record
  # must be on the CURRENT page (never an unbounded lookup) — the same "only what
  # `reads/3` already surfaced" discipline `select`/`select_all` use.
  #
  # `config.resource` is a HOST-AGNOSTIC name (e.g. `Plan`, unaliased — samen_web is
  # mounted by demo/driftwood/pawchart, each with its OWN concrete `<Namespace>.Plan`
  # module; the framework cannot know which at compile time). Every OTHER consumer
  # resolves it the same way: `Samen.Web.Mount.resource(mount, config.resource)`
  # (`Module.concat/2` — see `Reads.plans_page/3`'s `Mount.resource(mount, Plan)`) —
  # `Samen.Info.archivable?/1` must run on THAT resolved module, never the bare name.
  def handle_list_event("restore", %{"id" => id}, socket) do
    %{mount: mount, scope: scope, config: config, state: state} = list_assigns(socket)
    resource = config.resource && Samen.Web.Mount.resource(mount, config.resource)

    if resource && Samen.Info.archivable?(resource) do
      case Enum.find(socket.assigns.page.items, &(to_string(&1.id) == id)) do
        nil -> {:noreply, socket}
        record -> restore_and_reread(record, config.write_scope.(scope, socket), state, socket)
      end
    else
      {:noreply, socket}
    end
  end

  def handle_list_event(_event, _params, socket), do: {:noreply, socket}

  @doc "The list events this mixin owns (the hook halts exactly these)."
  def events, do: @events

  # -- internals ---------------------------------------------------------------

  # Re-run the BOUNDED read for `state` and assign `:list_state` + `:page`. The read is
  # the caller's `reads/3`, which returns a `%Page{}` built by `Samen.Web.Reads.page!/3`
  # (limit always applied) — the mixin never issues an unbounded read.
  defp reread(socket, %ListState{} = state) do
    %{mount: mount, scope: scope, config: config} = list_assigns(socket)

    page = config.reads.(mount, scope, state)

    socket
    |> Phoenix.Component.assign(:list_state, state)
    |> Phoenix.Component.assign(:page, %{page | prev_cursor: List.first(state.cursor_stack)})
  end

  # The `search.used` framework choke point (WS-B / G12, design §4.2). Every list view
  # that `use`s this mixin inherits emission at 0 LOC — a non-blank filter box query IS a
  # search. Best-effort (a track failure never affects the re-read that already ran) and
  # token-blind by construction: only the BOUNDED surface (the mount kind) + an integer
  # result count travel — the query TEXT is NEVER forwarded (it is a freeform string the
  # capture boundary would refuse; this source never even builds it). A blank filter (the
  # "clear search" case) emits nothing.
  defp emit_search_used(socket, filter) when is_binary(filter) and filter != "" do
    ctx = socket.assigns[:samen_list_ctx]
    org_id = socket.assigns[:org_id]

    if is_binary(org_id) and org_id != "" and match?(%{mount: %{scope_kind: _}}, ctx) do
      result_count = length(socket.assigns.page.items)

      _ =
        Samen.Analytics.Sources.search_used(org_id, ctx.mount.scope_kind,
          result_count: result_count
        )
    end

    :ok
  end

  defp emit_search_used(_socket, _filter), do: :ok

  # Scoped restore (never `authorize?: false` — the actor's own write policy governs,
  # same as every other mixin-triggered write). On success, re-read (the row leaves
  # the archived set / rejoins the live set, so the current page must reflect that).
  # On failure (e.g. `{:error, :restore_conflict}` — a live row now claims the unique
  # slot, §5.3), the socket is left as-is; the row still shows archived, honest.
  defp restore_and_reread(record, scope, state, socket) do
    case Samen.Archival.restore(record, scope: scope) do
      {:ok, _restored} -> {:noreply, reread(socket, state)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  defp assign_state(socket, state), do: Phoenix.Component.assign(socket, :list_state, state)

  defp list_assigns(socket) do
    %{view: view, mount: mount, scope: scope} = socket.assigns.samen_list_ctx

    %{
      view: view,
      mount: mount,
      scope: scope,
      config: view.__list_config__(),
      state: socket.assigns[:list_state] || %ListState{}
    }
  end

  # Match user input against the BOUNDED compile-time sortable list — never
  # `String.to_atom/1` on client input.
  defp bounded_field(sortable, field) when is_binary(field),
    do: Enum.find(sortable, fn f -> Atom.to_string(f) == field end)

  defp bounded_field(_sortable, _field), do: nil

  defp toggle_sort({field, :asc}, field), do: {field, :desc}
  defp toggle_sort({field, :desc}, field), do: {field, :asc}
  defp toggle_sort(_current, field), do: {field, :asc}

  defp filter_param(%{"filter" => q}) when is_binary(q), do: q
  defp filter_param(%{"value" => q}) when is_binary(q), do: q
  defp filter_param(_), do: ""

  # Attach the handle_event hook on a REAL mounted socket (one with a lifecycle in
  # `socket.private`). The bare `%Socket{}` the test harness builds has no lifecycle —
  # there the handler is invoked directly (`handle_list_event/3`), same code path.
  defp maybe_attach_hook(%Phoenix.LiveView.Socket{private: %{lifecycle: lifecycle}} = socket) do
    if Enum.any?(lifecycle.handle_event, &(&1.id == @hook_id)) do
      socket
    else
      Phoenix.LiveView.attach_hook(socket, @hook_id, :handle_event, &__MODULE__.on_event/3)
    end
  end

  defp maybe_attach_hook(socket), do: socket
end
