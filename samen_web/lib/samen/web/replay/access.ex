defmodule Samen.Web.Replay.Access do
  @moduledoc """
  WHO may watch a replay (ADR-052 §2.3 rule 2, D4) — the player's authorization chokepoint.
  Every list, every open and every frame batch of `Samen.Web.Replay.IndexLive` /
  `Samen.Web.Replay.PlayerLive` calls `authorize/3` again; nothing is cached between calls.

  **Watching is impersonating.**

    * **Operator plane** (`samen_operator_routes/2`, behind the T146 `:require_operator`
      on_mount): the operator must hold an ACTIVE impersonation session for the replay's org —
      `Samen.Web.Operator.Impersonation.gate_socket/3`, the same deny-on-read gate (and R-B
      scope conjunct) every per-tenant drill-in uses. The viewer scope IS that session's
      impersonation scope (`plane: :operator` + the real session marker, member-equivalent, no
      reveal grant), so `Samen.Api.PiiResolution` keeps every referenced field `••••` unless a
      separate live reveal grant covers the subject. No session → `{:error, :no_session}`.
    * **Tenant plane** (`samen_settings_routes/3`, behind `Samen.Web.TenantAuthz`): only a
      member of the SAME org holding an admin-class role (`:admin` or `:owner`,
      `Samen.Scope.Role.at_least?/2`) read from the principal's real `Identity.Membership`
      (the `RevealApprovalsLive` / `InvitationsLive` precedent). On an armed host the org must
      be in the principal's pinned authorized set (`Samen.Web.TenantAuthz`) — a client `?org=`
      cannot name another org. An operator-plane (impersonated) settings mount is refused: an
      operator watches through the operator routes, under a session.

  Returns `{:ok, viewer}` — `%{plane, scope, viewer_id, org_id, impersonation_session_id}` —
  or `{:error, reason}` with a bounded reason. Fail closed: anything unresolvable denies.

  Tier-1 mutation target (`scripts/mutation/targets.tsv`).
  """

  alias Samen.Web.{Mount, Operator}
  alias Samen.Web.Settings.Reads

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @type viewer :: %{
          plane: :operator | :tenant,
          scope: Samen.Scope.t(),
          viewer_id: String.t(),
          org_id: String.t(),
          impersonation_session_id: String.t() | nil
        }

  @type reason ::
          :no_org | :no_plane | :no_session | :out_of_scope | :operator_plane | :cross_org | :not_admin

  @doc """
  Authorize the socket's viewer for replays of `org_id`. `principal` is the tenant viewer's
  user id (resolved by the caller from the SIGNED session, `Samen.Web.Settings.Reads`); the
  operator viewer's id comes from the socket (`Samen.Web.Operator.Impersonation`).
  """
  @spec authorize(Phoenix.LiveView.Socket.t() | map(), String.t() | nil, String.t() | nil) ::
          {:ok, viewer()} | {:error, reason()}
  def authorize(socket, org_id, principal \\ nil) do
    mount = assigns(socket)[:samen_mount]

    cond do
      not uuid?(org_id) -> {:error, :no_org}
      operator_mount?(mount) -> operator(socket, String.downcase(org_id))
      match?(%Mount{plane: %{kind: :operator}}, mount) -> {:error, :operator_plane}
      tenant_mount?(mount) -> tenant(socket, mount, String.downcase(org_id), principal)
      true -> {:error, :no_plane}
    end
  end

  @doc "Is this the operator-plane player (an `:operator` workspace mount)?"
  @spec operator_mount?(term()) :: boolean()
  def operator_mount?(%Mount{scope_kind: :operator}), do: true
  def operator_mount?(_), do: false

  # ---------------------------------------------------------------------------
  # Operator: an ACTIVE impersonation session for this org, re-read on every call.

  defp operator(socket, org_id) do
    operator_id = assigns(socket)[:samen_operator_id]

    case Operator.Impersonation.gate_socket(socket, operator_id, org_id) do
      {:ok, %{impersonation: %{session_id: session_id} = marker} = actor, _info}
      when is_binary(session_id) ->
        {:ok,
         %{
           plane: :operator,
           scope: %Samen.Scope{actor: actor, context: %{samen_impersonation: marker}},
           viewer_id: operator_id,
           org_id: org_id,
           impersonation_session_id: session_id
         }}

      :out_of_scope ->
        {:error, :out_of_scope}

      _ ->
        {:error, :no_session}
    end
  end

  # ---------------------------------------------------------------------------
  # Tenant: an admin-class member of the SAME org.

  defp tenant(socket, mount, org_id, principal) do
    cond do
      not same_org?(assigns(socket)[:samen_authorized_orgs], org_id) ->
        {:error, :cross_org}

      not is_binary(principal) ->
        {:error, :not_admin}

      true ->
        %Samen.Scope{actor: actor} = Mount.scope(mount, org_id)
        role = membership_role(mount, org_id, principal)

        if Samen.Scope.Role.at_least?(role, :admin) do
          {:ok,
           %{
             plane: :tenant,
             scope: %Samen.Scope{actor: Map.put(actor, :role, role)},
             viewer_id: principal,
             org_id: org_id,
             impersonation_session_id: nil
           }}
        else
          {:error, :not_admin}
        end
    end
  end

  # Armed host: the org must be one the authenticated principal holds (pinned by TenantAuthz).
  # Disarmed (`:unconstrained`): the membership check below is the gate.
  defp same_org?(:unconstrained, _org_id), do: true

  defp same_org?(orgs, org_id) when is_list(orgs),
    do: Enum.any?(orgs, &(is_binary(&1) and String.downcase(&1) == org_id))

  defp same_org?(_orgs, _org_id), do: false

  defp membership_role(mount, org_id, principal) do
    case Reads.current_membership(mount, Mount.scope(mount, org_id), principal, org_id) do
      {:ok, %{role: role}} -> role
      _ -> nil
    end
  end

  defp tenant_mount?(%Mount{plane: %{kind: :tenant}, scope_kind: kind})
       when kind not in [:operator, :aggregate],
       do: true

  defp tenant_mount?(_), do: false

  defp assigns(%{assigns: assigns}) when is_map(assigns), do: assigns
  defp assigns(assigns) when is_map(assigns), do: assigns

  defp uuid?(v) when is_binary(v), do: Regex.match?(@uuid, v)
  defp uuid?(_), do: false
end
