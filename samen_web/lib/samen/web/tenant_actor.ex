defmodule Samen.Web.TenantActor do
  @moduledoc """
  The ONE resolver that turns "who is signed in" into the tenant Ash scope a surface acts with
  (ADR-045 §4.4 residual: the `:member` default of `Samen.Web.Plane.scope/2`).

  `Plane.scope/2` / `Mount.scope/2` fabricate a synthetic org-level actor (`broker:<org>`) with a
  FIXED `role: :member`. A signed-in `:viewer` therefore acted as a member on every surface that
  used it. This module derives the role (and the per-org user id) from the person's ACTIVE
  `Identity.Membership` through the same resolver the notification surfaces use
  (`Samen.Web.Settings.Reads.actor_in_org/3` over `Samen.Auth.OrgActor`) — no second copy.

  ## Outcomes of `scope/3`

    * `{:ok, scope}` — the actor carries the resolved role and user id, and is marked `resolved: true`: a
      marker that the role came from a membership (the tests and diagnostics read it), NOT a cache — every
      call does its own lookup.
    * `:denied` — ARMED host, no active membership in the org (or no principal at all). The surface
      refuses: it renders the honest denied state, it never falls back to a default role.
    * `{:error, :unavailable}` — the lookup failed. An error state, never an empty page, never access.

  ## Postures (unchanged where they were not the bug)

    * OPERATOR plane (impersonation / operator console): the plane's own scope for READS, unchanged. A tenant page there is
      read-only (`recheck_event/3` refuses every non-read event, `write_scope/3` is not an admin); acting in a tenant is
      impersonation's route (T146/T150), not a membership.
    * DISARMED dev posture (`CurrentOrg.tenant_gate_armed?/1` false): the historical synthetic
      `:member` scope, byte for byte, via `system_scope/2`. There is no authenticated person to resolve.
    * ARMED: the resolved membership role, as above.

  A caller that legitimately needs a fixed role (a job, a seed, a system context) must say so by name:
  `system_scope/2`. `Samen.Web.TenantActorGuardTest` fails on a new implicit `Mount.scope/2` in tenant
  web code.
  """

  alias Samen.Web.{CurrentOrg, Mount, Plane}
  alias Samen.Web.Settings.Reads

  @type result :: {:ok, Samen.Scope.t()} | :denied | {:error, :unavailable}

  @doc """
  The synthetic org-level scope with its FIXED `:member` role, by name. For system / job / seed
  contexts and the disarmed dev posture only; a surface acting for a signed-in person uses `scope/3`.
  """
  @spec system_scope(Mount.t(), String.t() | nil) :: Samen.Scope.t()
  def system_scope(%Mount{plane: plane}, org_id), do: Plane.scope(plane, org_id)

  @doc "The acting scope for `ref` (a `Settings.Reads.principal_ref/3`) in `org_id`. See the moduledoc."
  @spec scope(Mount.t() | nil, String.t() | nil, Reads.principal_ref() | nil) :: result()
  def scope(%Mount{plane: %{kind: :operator}} = mount, org_id, _ref), do: {:ok, system_scope(mount, org_id)}
  def scope(nil, _org_id, _ref), do: :denied
  def scope(_mount, nil, _ref), do: :denied

  def scope(%Mount{} = mount, org_id, ref) do
    if CurrentOrg.tenant_gate_armed?(mount) do
      armed(mount, org_id, ref || :none)
    else
      {:ok, system_scope(mount, org_id)}
    end
  end

  # The dev leg (`{:dev, _}`) is a DISARMED-only posture: `Reads.principal_ref/3` only produces it when the
  # `?user=` / `:current_user_id` trust is on, and `actor_in_org/3` would act as the named user (or a default
  # `:member`). On an armed mount it is refused, whatever produced it.
  defp armed(_mount, _org_id, {:dev, _id}), do: :denied

  defp armed(mount, org_id, ref) do
    case Reads.actor_in_org(mount, org_id, ref) do
      {:ok, %{id: id, role: role}} -> {:ok, resolved(mount, org_id, id, role)}
      :none -> :denied
      :denied -> :denied
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp resolved(mount, org_id, user_id, role) do
    %Samen.Scope{actor: actor} = system_scope(mount, org_id)
    %Samen.Scope{actor: actor |> Map.merge(%{id: user_id, role: role}) |> Map.put(:resolved, true)}
  end

  @doc """
  The scope of a user a surface ALREADY resolved (`user_id`, and `role` when the membership gave one): the plane's synthetic
  actor carrying that user and role. The tenant plane's actor (`broker:<org>`) names no user, so a surface that is the
  person's own (the inbox, preferences, a profile) carries the user the session resolved; `role` nil keeps the plane's.
  An operator-plane scope, or no user, is returned as the plane built it.
  """
  @spec user_scope(Mount.t(), String.t() | nil, String.t() | nil, atom() | nil) :: Samen.Scope.t()
  def user_scope(%Mount{} = mount, org_id, user_id, role \\ nil) do
    case {system_scope(mount, org_id), user_id} do
      {%Samen.Scope{actor: %{plane: :tenant} = actor} = scope, user_id} when is_binary(user_id) ->
        %{scope | actor: %{actor | id: user_id, role: role || actor.role}}

      {scope, _no_session_user} ->
        scope
    end
  end

  @doc """
  The role `ref` acts with in `org_id`, for a surface that builds its own actor map (the generated `--live`
  screens): `{:ok, role}` or `{:refused, :denied | :unavailable}`.

  ARMED: the resolved membership role (`scope/3`). DISARMED dev posture: `disarmed_role`, named by the
  caller (the generated screens keep their `:admin` dev convenience). There is no default role: a refusal
  carries none.
  """
  @spec access(Mount.t(), String.t() | nil, Reads.principal_ref() | nil, atom()) ::
          {:ok, atom()} | {:refused, :denied | :unavailable}
  def access(%Mount{} = mount, org_id, ref, disarmed_role) do
    if CurrentOrg.tenant_gate_armed?(mount) do
      case scope(mount, org_id, ref) do
        {:ok, %Samen.Scope{actor: %{role: role}}} -> {:ok, role}
        :denied -> {:refused, :denied}
        {:error, :unavailable} -> {:refused, :unavailable}
      end
    else
      {:ok, disarmed_role}
    end
  end

  @doc """
  Whether a page offers its WRITE controls (the create / edit / delete / enroll buttons): the plane may write
  (`Samen.Web.Live`'s `writable?/1`, an operator never authors into a tenant) AND the person acting holds at least the
  `:member` role every tenant write of these surfaces needs. A viewer's page renders no write control, a refused page
  (`nil` scope) none either. `assign_actor/2` assigns the answer as `:can_write`, which is what the templates read. This is
  what the page SHOWS; what it ALLOWS is the kernel policy, which is unchanged.
  """
  @spec writable?(Mount.t() | nil, Samen.Scope.t() | nil) :: boolean()
  def writable?(%Mount{plane: %{kind: :operator}}, _scope), do: false
  def writable?(%Mount{}, %Samen.Scope{actor: %{role: role}}), do: Samen.Scope.Role.at_least?(role, :member)
  def writable?(%Mount{}, _no_scope), do: false

  @doc """
  Whether the person acting on `socket` holds at least the `:member` role (the plane is not asked): the page-level gate for
  a write whose resource only checks the org in the kernel (a reply, a customer, an article). `false` when nobody acts.

  A RANK check only, deliberately unlike `admin?/1`: on the operator plane the synthetic scope carries `:member`, so this is
  true there, and what stops an operator's write is the kernel's plane guard (`Samen.Pii.WriteGuard` refuses a plaintext PII
  write on that plane; `writable?/2` hides the controls). Answering `false` here would turn those refusals into this page's
  flash and stop the kernel guards being the thing reached, which the operator red paths exist to prove.
  """
  @spec member?(map()) :: boolean()
  def member?(%{assigns: %{acting_scope: %Samen.Scope{actor: %{role: role}}}}), do: Samen.Scope.Role.at_least?(role, :member)
  def member?(_socket), do: false

  @doc """
  The page-level gate of an ADMIN-ranked action the kernel does not itself gate (sending a campaign): on an armed tenant
  plane the person acting must hold at least `:admin`; the disarmed dev posture (no authenticated person) is open. The
  OPERATOR plane is `false`, like `administrable?/2`: an operator never sends a tenant's campaign. `false` when nobody acts.
  """
  @spec admin?(map()) :: boolean()
  def admin?(%{assigns: %{acting_scope: %Samen.Scope{}, samen_mount: %Mount{plane: %{kind: :operator}}}}), do: false

  def admin?(%{assigns: %{acting_scope: %Samen.Scope{actor: %{role: role}}, samen_mount: %Mount{} = mount}}) do
    not CurrentOrg.tenant_gate_armed?(mount) or Samen.Scope.Role.at_least?(role, :admin)
  end

  def admin?(_socket), do: false

  @doc """
  Whether a page offers its ADMIN-ranked write controls (the billing, plan, invoice, campaign and segment writes the kernel
  reserves for `RoleAtLeast :admin`): the plane may write, and the person acting holds at least `:admin`. On a DISARMED mount
  (the dev posture, where `write_scope/3` is the dev admin) the controls are offered, exactly as before. `assign_actor/2`
  assigns the answer as `:can_admin`. What the page SHOWS; what it ALLOWS is the kernel policy, which is unchanged.
  """
  @spec administrable?(Mount.t() | nil, Samen.Scope.t() | nil) :: boolean()
  def administrable?(%Mount{plane: %{kind: :operator}}, _scope), do: false

  def administrable?(%Mount{} = mount, %Samen.Scope{actor: %{role: role}}) do
    if CurrentOrg.tenant_gate_armed?(mount), do: Samen.Scope.Role.at_least?(role, :admin), else: true
  end

  def administrable?(_mount, _no_scope), do: false

  @doc """
  The scope an ADMIN-gated write runs with.

    * ARMED tenant plane: the acting scope itself (the person's real, current role and user id; the kernel policy refuses a
      viewer or a member). Anything that is not a `%Samen.Scope{}` (a page that is not acting passes `nil`) FAILS CLOSED: it
      raises `ArgumentError`; there is no fallback to a `:member` or an admin scope. A page that is refused never reaches a
      write (`refuse_events/1`).
    * OPERATOR plane: a tenant page there is read-only. The scope is the plane's actor with the lowest role and
      `read_only: true`, so the kernel refuses what it gates and `recheck_event/3` refuses the event before it gets here.
    * DISARMED dev posture: the posture's own admin elevation (`Samen.Web.TenantRole.admin_scope/3`), byte for byte what
      that posture always did, whatever `acting` is.
  """
  @spec write_scope(Mount.t(), String.t(), Samen.Scope.t() | nil) :: Samen.Scope.t()
  def write_scope(%Mount{plane: %{kind: :tenant}} = mount, org_id, acting) do
    cond do
      not CurrentOrg.tenant_gate_armed?(mount) -> Samen.Web.TenantRole.admin_scope(mount, org_id)
      match?(%Samen.Scope{}, acting) -> acting
      true -> raise ArgumentError, "write_scope/3 on an armed tenant mount needs the acting %Samen.Scope{}, got: #{inspect(acting)}"
    end
  end

  # A tenant page on the OPERATOR plane is read-only: the scope its write path would use is the plane's own actor with the
  # lowest role and a `read_only` marker, never an admin elevation. (Acting in a tenant is what impersonation is for.)
  def write_scope(%Mount{plane: %{kind: :operator}} = mount, org_id, _acting) do
    %Samen.Scope{actor: actor} = system_scope(mount, org_id)
    %Samen.Scope{actor: actor |> Map.put(:role, lowest_role()) |> Map.put(:read_only, true)}
  end

  def write_scope(%Mount{} = mount, org_id, _acting), do: Samen.Web.TenantRole.admin_scope(mount, org_id)

  defp lowest_role, do: Enum.min_by(Samen.Scope.Role.all(), &Samen.Scope.Role.rank/1)

  @doc """
  The principal reference for a request: pinned by `Samen.Web.TenantAuthz` as `:samen_principal_ref`
  on every tenant socket; a controller derives it from its session.
  """
  @spec conn_ref(Mount.t() | nil, map(), map()) :: Reads.principal_ref()
  def conn_ref(mount, params, session), do: Reads.principal_ref(mount, params, session)

  @doc """
  The acting scope on a LiveView socket for `org_id`, from the principal `Samen.Web.TenantAuthz` pinned as
  `:samen_principal_ref`. A socket that never ran the tenant gate (no ref pinned) is `:denied` on an ARMED mount:
  there is nobody to resolve, and a fixed `:member` is exactly the bug this module exists to close (a host that
  mounts a converted LiveView in its own `live_session` without the hook gets the denied state, not a member).
  On a DISARMED mount the dev posture applies (`system_scope/2`, named).
  """
  @spec socket_scope(Phoenix.LiveView.Socket.t() | map(), String.t() | nil) :: result()
  def socket_scope(socket, org_id) do
    assigns = assigns(socket)
    mount = assigns[:samen_mount]

    cond do
      is_nil(mount) -> :denied
      Map.has_key?(assigns, :samen_principal_ref) -> scope(mount, org_id, assigns[:samen_principal_ref])
      CurrentOrg.tenant_gate_armed?(mount) -> :denied
      true -> {:ok, system_scope(mount, org_id)}
    end
  end

  @doc """
  Resolve who acts on `socket` for `org_id` (`socket_scope/2`) and ASSIGN the outcome, the one way every converted
  LiveView does it: `:acting_scope` (the scope, or `nil`) and `:actor_state` (`:ok`, `:denied`, `:unavailable`).

    * `{:ok, socket}` - `acting_scope` is the resolved scope, `actor_state` is `:ok`.
    * `{:refused, socket}` - `acting_scope` is `nil` (a scope from before the refusal does not survive it), `actor_state`
      is `:denied` or `:unavailable`. The caller then renders `Samen.Web.TenantActor.Components.actor_refused/1`, reads
      nothing, and takes any list context away (`Samen.Web.ListLive.refuse/1`).

  ## An open page does not keep the role it resolved

  The first call on a mounted socket also attaches the event guard (`recheck_event/3`, a `:handle_event` lifecycle hook,
  attached once however many times `assign_actor/2` runs): before EVERY event the actor is resolved again for the
  org the page is pinned to, so a member suspended or demoted while the page is open is judged by the membership as it
  is now, not as it was at the last navigation. See `recheck_event/3`.

  A call on a page that already acted (a navigation, a reload after a write) compares the person it resolves now with the one
  the page held: another id, another role, or another organisation runs the view's `actor_changed/1`, as on the event path.
  """
  @spec assign_actor(Phoenix.LiveView.Socket.t(), String.t() | nil) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:refused, Phoenix.LiveView.Socket.t()}
  def assign_actor(socket, org_id) do
    held = assigns(socket)[:acting_scope]
    held_org = assigns(socket)[:acting_org_id]

    socket
    |> Phoenix.Component.assign(:acting_org_id, org_id)
    |> attach_guard()
    |> resolve_into(org_id)
    |> navigated(held, held_org != org_id)
  end

  # A navigation (`handle_params`, a reload after a write) runs `assign_actor/2` again on a page that already acted. When
  # the person acting is not the one the page held (another id, another role) or the organisation changed, the page's
  # `actor_changed/1` runs exactly as it does on the event path (`follow/2`): whatever it built with the old scope (an
  # open form) is built again with the fresh one, or closed. Without this the held scope is replaced silently, the next
  # event's recheck sees no change, and a form built before a demotion or an `?org=` switch is submitted with the
  # authority it was built with. A page that was not acting (`held` is not a scope: first mount, refused before) has
  # nothing built with a scope to follow, and a refusal is the view's own load (`actor_lost/1` is its refused branch).
  defp navigated({:ok, socket}, %Samen.Scope{} = held, org_changed?), do: {:ok, follow(socket, held, org_changed?)}
  defp navigated(result, _held, _org_changed?), do: result

  # `can_write` is what the page SHOWS (its write controls): computed here, with the scope, as a plain assign, so a page
  # that is replayed from its recorded assigns (a `Samen.Scope` is not recorded) renders the controls its person saw.
  defp resolve_into(socket, org_id) do
    case socket_scope(socket, org_id) do
      {:ok, scope} ->
        mount = assigns(socket)[:samen_mount]
        {:ok,
         Phoenix.Component.assign(socket,
           acting_scope: scope,
           actor_state: :ok,
           can_write: writable?(mount, scope),
           can_admin: administrable?(mount, scope)
         )}

      :denied ->
        {:refused, Phoenix.Component.assign(socket, acting_scope: nil, actor_state: :denied, can_write: false, can_admin: false)}

      {:error, :unavailable} ->
        {:refused, Phoenix.Component.assign(socket, acting_scope: nil, actor_state: :unavailable, can_write: false, can_admin: false)}
    end
  end

  # -- the event guard: re-resolve who acts before EVERY event ------------------------------------------------------

  @guard_id :samen_tenant_actor_guard
  @uri_id :samen_tenant_actor_uri

  # A routed view also records the URI it was patched to (`:acting_uri`), which is where `retry_actor` re-runs it.
  defp attach_guard(socket) do
    socket = attach_once(socket, @guard_id, :handle_event, &__MODULE__.recheck_event/3)

    if is_nil(socket.router),
      do: socket,
      else: attach_once(socket, @uri_id, :handle_params, &__MODULE__.remember_uri/3)
  end

  @doc """
  Attach a lifecycle hook ONCE: a no-op when `id` is already attached at `stage` (a `handle_params` re-entry runs the
  caller again on every navigation), and a no-op on a bare `%Socket{}` with no lifecycle (the unit harness; a real mounted
  socket always has one). The surfaces that do not resolve through `assign_actor/2` (the notification pages resolve the
  recipient their own way) attach their own guard with it.
  """
  @spec attach_once(Phoenix.LiveView.Socket.t(), atom(), atom(), function()) :: Phoenix.LiveView.Socket.t()
  def attach_once(%Phoenix.LiveView.Socket{private: %{lifecycle: lifecycle}} = socket, id, stage, fun) do
    if Enum.any?(Map.fetch!(lifecycle, stage), &(&1.id == id)),
      do: socket,
      else: Phoenix.LiveView.attach_hook(socket, id, stage, fun)
  end

  def attach_once(socket, _id, _stage, _fun), do: socket

  @doc false
  def remember_uri(_params, uri, socket), do: {:cont, Phoenix.Component.assign(socket, :acting_uri, uri)}

  @doc """
  The `:handle_event` lifecycle hook `assign_actor/2` attaches: it runs BEFORE the `ListLive` hook and before the view's
  own `handle_event/3` (hooks run in attach order and `assign_actor/2` is the first thing a page's `load` does), and it
  re-resolves the actor for the org the page is pinned to (`:acting_org_id`) on every event:

    * the page is not acting (no org, or already the denied / unavailable state): `{:cont, socket}`; `refuse_events/1` is
      the second line of defence for those.
    * `{:ok, scope}`: `acting_scope` becomes the fresh scope (a demotion takes effect on the very next event), the
      `ListLive` context follows (it keeps its own scope), and a view that built anything with the old scope (a form)
      rebuilds it in its `actor_changed/1` when the person's role or id changed.
    * `:denied` / `{:error, :unavailable}`: the page switches to the refused state (`acting_scope` nil, the list context
      taken away, and everything it loaded dropped: the view's optional `actor_lost/1` callback, mirroring
      `actor_changed/1`, runs the same load a refused navigation does) and the event is HALTED - no later hook and no `handle_event/3` sees it.

  `"retry_actor"` (the button of `Samen.Web.TenantActor.Components.actor_refused/1`) re-resolves the same way and, when the
  person acts again, patches to the page's own URL so it loads fresh; a page with no URL to patch to (no router, or none
  recorded) re-runs its own load in place (the view's optional `actor_regained/1`).
  """
  def recheck_event("retry_actor", _params, socket), do: {:halt, retry(socket)}

  def recheck_event(event, params, socket) do
    if operator_write_event?(event, socket),
      do: {:halt, refuse_operator_write(socket)},
      else: recheck_actor(event, params, socket)
  end

  # A tenant page on the OPERATOR plane is read-only (impersonation is the route for acting in a tenant). The refusal is
  # here, in the one hook every acting page attaches, and it is by default: only the events named read events (the list's
  # own, a retry, a tab, a form validation or cancel, which persist nothing) pass; any other event, including one a page
  # adds later, is refused with the page's own flash. `retry_actor` is handled before this.
  @read_events ~w(retry_load list_retry sort filter paginate select select_all toggle_archived switch_tab board_load_more
                  insert_suggestion insert_macro open_ents cancel_ents search retry_search)

  defp operator_write_event?(event, %{assigns: %{samen_mount: %Mount{plane: %{kind: :operator}}, acting_scope: %Samen.Scope{}}}) do
    not (event in @read_events or String.starts_with?(event, "validate") or String.starts_with?(event, "cancel"))
  end

  defp operator_write_event?(_event, _socket), do: false

  @read_only_copy "You are viewing this organisation as an operator. To make a change, impersonate it."

  defp refuse_operator_write(socket), do: Phoenix.LiveView.put_flash(socket, :error, @read_only_copy)

  defp recheck_actor(_event, _params, socket) do
    case socket.assigns do
      %{acting_scope: %Samen.Scope{} = held, acting_org_id: org_id} when is_binary(org_id) ->
        case resolve_into(socket, org_id) do
          {:ok, socket} -> {:cont, follow(socket, held, false)}
          {:refused, socket} -> {:halt, scrub(socket)}
        end

      _not_acting ->
        {:cont, socket}
    end
  end

  defp retry(%{assigns: %{acting_org_id: org_id}} = socket) when is_binary(org_id) do
    case resolve_into(socket, org_id) do
      {:ok, _acting} -> patch_to_self(socket)
      {:refused, refused} -> scrub(refused)
    end
  end

  defp retry(socket), do: socket

  # Acting again. A routed page with a URL to go back to loads fresh through its own `handle_params` (nothing is rebuilt
  # here by hand; until it does it stays the refused state it was). A page with none (no router, so a patch would raise,
  # or one that never recorded where it is) re-runs its own load in place, through the view's `actor_regained/1`: the
  # click always does something honest, never nothing.
  defp patch_to_self(%{router: router} = socket) when not is_nil(router) do
    case socket.assigns[:acting_uri] || socket.assigns[:return_to] do
      uri when is_binary(uri) ->
        %URI{path: path, query: query} = URI.parse(uri)
        Phoenix.LiveView.push_patch(socket, to: if(query, do: "#{path}?#{query}", else: path))

      _unknown ->
        actor_regained(socket)
    end
  end

  defp patch_to_self(socket), do: actor_regained(socket)

  defp actor_regained(%{view: view} = socket) when is_atom(view) and not is_nil(view) do
    if Code.ensure_loaded?(view) and function_exported?(view, :actor_regained, 1),
      do: view.actor_regained(socket),
      else: socket
  end

  defp actor_regained(socket), do: socket

  # The refused state: the person is no longer acting, so the page keeps nothing it loaded for them. The shared parts go
  # here (the list context, the list page); everything else the view loaded (a record's name in a topbar, its forms, its
  # tiles) is dropped by the view's own `actor_lost/1`, the same load a refused navigation does.
  defp scrub(socket) do
    socket = Samen.Web.ListLive.refuse(socket)

    socket =
      case socket.assigns do
        %{page: %Samen.Web.Page{}} -> Phoenix.Component.assign(socket, :page, %Samen.Web.Page{})
        _ -> socket
      end

    drop_loaded(socket)
  end

  defp drop_loaded(%{view: view} = socket) when is_atom(view) and not is_nil(view) do
    if Code.ensure_loaded?(view) and function_exported?(view, :actor_lost, 1),
      do: view.actor_lost(socket),
      else: socket
  end

  defp drop_loaded(socket), do: socket

  # The person is still acting; their scope is the fresh one. Whatever else the page kept from the old scope follows.
  defp follow(socket, %Samen.Scope{actor: held}, org_changed?) do
    %Samen.Scope{actor: fresh} = socket.assigns.acting_scope
    socket = follow_list_ctx(socket, fresh)

    if not org_changed? and {held[:id], held[:role]} == {fresh[:id], fresh[:role]},
      do: socket,
      else: actor_changed(socket)
  end

  # `ListLive` keeps its own scope (its read AND its `restore` write context): same scope, the person's fresh id + role.
  defp follow_list_ctx(%{assigns: %{samen_list_ctx: %{scope: %Samen.Scope{actor: actor} = scope} = ctx}} = socket, fresh) do
    ctx = %{ctx | scope: %{scope | actor: Map.merge(actor, %{id: fresh[:id], role: fresh[:role]})}}
    Phoenix.Component.assign(socket, :samen_list_ctx, ctx)
  end

  defp follow_list_ctx(socket, _fresh), do: socket

  defp actor_changed(%{view: view} = socket) when is_atom(view) and not is_nil(view) do
    if Code.ensure_loaded?(view) and function_exported?(view, :actor_changed, 1),
      do: view.actor_changed(socket),
      else: socket
  end

  defp actor_changed(socket), do: socket

  @doc """
  The shared `handle_event/3` guard of a converted LiveView: define it BEFORE the view's own clauses (after
  `@impl true`), and an event that arrives while nobody is acting is a no-op.

      require Samen.Web.TenantActor

      @impl true
      Samen.Web.TenantActor.refuse_events()          # every event: acting_scope is nil, or actor_state is not :ok
      Samen.Web.TenantActor.refuse_events(["save"])  # only these events, while actor_state is not :ok

  The named form is for a view whose other events (a retry) must still work from the refused state. A socket with
  neither assign is not refused here: `assign_actor/2` always sets them in `load`.
  """
  defmacro refuse_events(events \\ :all) do
    case events do
      :all ->
        quote do
          def handle_event(_event, _params, %{assigns: %{acting_scope: nil}} = socket), do: {:noreply, socket}

          def handle_event(_event, _params, %{assigns: %{actor_state: state}} = socket) when state != :ok,
            do: {:noreply, socket}
        end

      names when is_list(names) ->
        quote do
          def handle_event(event, _params, %{assigns: %{actor_state: state}} = socket)
              when event in unquote(names) and state != :ok,
              do: {:noreply, socket}
        end
    end
  end

  defp assigns(%{assigns: a}) when is_map(a), do: a
  defp assigns(a) when is_map(a), do: a
end
