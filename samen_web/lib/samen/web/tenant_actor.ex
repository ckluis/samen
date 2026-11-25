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

    * `{:ok, scope}` — the actor carries the resolved role and user id, and is marked
      `resolved: true` (so a second pass does not look it up again).
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
  The principal reference for a request: pinned by `Samen.Web.TenantAuthz` as `:samen_principal_ref`
  on every tenant socket; a controller derives it from its session.
  """
  @spec conn_ref(Mount.t() | nil, map(), map()) :: Reads.principal_ref()
  def conn_ref(mount, params, session), do: Reads.principal_ref(mount, params, session)

  @doc """
  The acting scope on a LiveView socket for `org_id`. A socket that never ran the tenant gate
  (no `:samen_principal_ref` pinned: a synthetic mount outside the framework routes, which the
  tenant-authn coverage tests forbid for real routes) acts through `system_scope/2`, named.
  """
  @spec socket_scope(Phoenix.LiveView.Socket.t() | map(), String.t() | nil) :: result()
  def socket_scope(socket, org_id) do
    assigns = assigns(socket)
    mount = assigns[:samen_mount]

    if Map.has_key?(assigns, :samen_principal_ref) do
      scope(mount, org_id, assigns[:samen_principal_ref])
    else
      {:ok, system_scope(mount, org_id)}
    end
  end

  defp assigns(%{assigns: a}) when is_map(a), do: a
  defp assigns(a) when is_map(a), do: a
end
