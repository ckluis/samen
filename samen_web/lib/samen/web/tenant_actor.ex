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

    * OPERATOR plane (impersonation / operator console): the plane's own scope, unchanged. Its
      authority is T146/T150, not a membership.
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
  (`nil` scope) none either. This is what the page SHOWS; what it ALLOWS is the kernel policy, which is unchanged.
  """
  @spec writable?(Mount.t() | nil, Samen.Scope.t() | nil) :: boolean()
  def writable?(%Mount{plane: %{kind: :operator}}, _scope), do: false
  def writable?(%Mount{}, %Samen.Scope{actor: %{role: role}}), do: Samen.Scope.Role.at_least?(role, :member)
  def writable?(_mount, _scope), do: false

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
  """
  @spec assign_actor(Phoenix.LiveView.Socket.t(), String.t() | nil) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:refused, Phoenix.LiveView.Socket.t()}
  def assign_actor(socket, org_id) do
    socket
    |> Phoenix.Component.assign(:acting_org_id, org_id)
    |> attach_guard()
    |> resolve_into(org_id)
  end

  defp resolve_into(socket, org_id) do
    case socket_scope(socket, org_id) do
      {:ok, scope} -> {:ok, Phoenix.Component.assign(socket, acting_scope: scope, actor_state: :ok)}
      :denied -> {:refused, Phoenix.Component.assign(socket, acting_scope: nil, actor_state: :denied)}
      {:error, :unavailable} -> {:refused, Phoenix.Component.assign(socket, acting_scope: nil, actor_state: :unavailable)}
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
      taken away, the data it held cleared) and the event is HALTED - no later hook and no `handle_event/3` sees it.

  `"retry_actor"` (the button of `Samen.Web.TenantActor.Components.actor_refused/1`) re-resolves the same way and, when the
  person acts again, patches to the page's own URL so it loads fresh.
  """
  def recheck_event("retry_actor", _params, socket), do: {:halt, retry(socket)}

  def recheck_event(_event, _params, socket) do
    case socket.assigns do
      %{acting_scope: %Samen.Scope{} = held, acting_org_id: org_id} when is_binary(org_id) ->
        case resolve_into(socket, org_id) do
          {:ok, socket} -> {:cont, follow(socket, held)}
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

  # Acting again: the page loads fresh through its own `handle_params` (nothing is rebuilt here by hand); until it does
  # it stays the refused state it was.
  defp patch_to_self(socket) do
    case socket.assigns[:acting_uri] || socket.assigns[:return_to] do
      uri when is_binary(uri) ->
        %URI{path: path, query: query} = URI.parse(uri)
        Phoenix.LiveView.push_patch(socket, to: if(query, do: "#{path}?#{query}", else: path))

      _unknown ->
        socket
    end
  end

  # The refused state: nothing the page loaded for the person it acted for is kept.
  defp scrub(socket) do
    socket = Samen.Web.ListLive.refuse(socket)

    case socket.assigns do
      %{page: %Samen.Web.Page{}} -> Phoenix.Component.assign(socket, :page, %Samen.Web.Page{})
      _ -> socket
    end
  end

  # The person is still acting; their scope is the fresh one. Whatever else the page kept from the old scope follows.
  defp follow(socket, %Samen.Scope{actor: held}) do
    %Samen.Scope{actor: fresh} = socket.assigns.acting_scope
    socket = follow_list_ctx(socket, fresh)

    if {held[:id], held[:role]} == {fresh[:id], fresh[:role]},
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
