defmodule Samen.Web.Operator.Impersonation do
  @moduledoc """
  The framework GATE + OPEN affordance that wires the operator per-tenant drill-in
  surfaces to the audited `Samen.Impersonation` session runtime (T150).

  ## The gap this closes (dogfood W4, HONESTY/ACCOUNTABILITY-HIGH)

  Before T150 the per-tenant operator drill-ins (`/operator/deliverability/:org_id`,
  `/operator/automation/:org_id`, `/operator/activity/:org_id`, and the freight-shaped
  `/operator/impersonate`) reached a SPECIFIC tenant's data through a SYNTHETIC marker
  (`Samen.Web.Plane.operator/3` fabricated `impersonation: %{session_id: "operator-session"}`,
  and `Samen.Web.Operator.DeliverabilityReads.operator_actor/1` fabricated
  `"operator-deliverability"`) that referenced NO real `imp_impersonation_session` row. An
  operator read one tenant's masked data with NO session, NO reason, and NO tenant-visible
  ledger entry — while `Samen.Web.Settings.SecurityLive` promises the tenant a ledger of
  "who accessed this org, when, and why." The `Samen.Impersonation.open/3` lifecycle
  (reason-required, same-tx audit, auto-expire) had ZERO non-test callers, so it was
  unreachable by any human path.

  This module is the missing bridge. A per-tenant drill-in mount now:

    1. resolves the acting operator identity from the AUTHENTICATED session principal (via
       `Samen.Web.Operator.Authz`'s `:samen_operator_id`/`:samen_operator_role` assigns),
       falling back to the operator seat's well-known org id;
    2. `gate/2` — consults `Samen.Impersonation.scope/3` (deny-on-read: an active, unexpired,
       un-suspended session for THIS operator over THIS target org) and DENIES when there is
       none, carrying the REAL session id in the produced actor so the access is attributable;
    3. `open/4` — the OPEN-SESSION-WITH-REASON affordance the drill-in's denied state renders
       as a `phx-submit="open_session"` form; it calls `Samen.Impersonation.open/3` so the
       access lands in the tenant's ledger with who/why/expiry, then the drill-in re-renders
       masked. On expiry (or close, or operator suspension) the next `gate/2` re-denies and the
       surface re-masks/denies — the kernel's per-request semantics, honored by the web path.

  ## What is NOT gated (deliberate — ADR-010 §7.2 identity line)

  The operator's OWN book of business — the cross-tenant PLATFORM views
  (`/operator/accounts`, `/operator/billing`, `/operator/revenue`, `/operator/flags`,
  `/operator/webhooks`, `/operator/analytics`, `/operator/aggregate`, `/operator/desk`) — is
  data the SaaS legitimately owns (tenant-admin contact + platform MRR). Those do NOT
  impersonate a specific tenant and are NOT gated here; their control is the T146 operator-ROLE
  gate. This module governs ONLY the per-tenant drill-ins (peering into ONE tenant's house).
  """

  alias Samen.OperatorPlane.Actor
  alias Samen.Web.{Auth, Mount, Operator}

  @roles Actor.roles()

  @doc """
  Resolve the ACTING operator id for an operator drill-in mount. Resolution order:

    1. an explicit `operator_id` query param (the local dogfood convenience identity),
    2. an `operator_id` on the session,
    3. the `:samen_operator_id` assign `Samen.Web.Operator.Authz` derived from the
       AUTHENTICATED session principal (the production path),
    4. the operator seat's well-known org id (`Samen.Web.Operator.org_id/1`) — a stable
       bounded id for the operator workspace, so a drill-in reached without an explicit
       principal (the disarmed dev dogfood) still has a consistent operator identity to open
       + gate a session under.

  Returns `nil` only when NONE resolves (no mount, no principal) → the gate denies.
  """
  @spec resolve_operator_id(Phoenix.LiveView.Socket.t(), map(), map()) :: String.t() | nil
  def resolve_operator_id(socket, session \\ %{}, params \\ %{}) do
    present(params["operator_id"]) ||
      present(Map.get(session, "operator_id")) ||
      present(socket.assigns[:samen_operator_id]) ||
      operator_seat_id(socket)
  end

  defp operator_seat_id(socket) do
    case socket.assigns[:samen_mount] do
      %Mount{} = mount -> Operator.org_id(mount)
      _ -> nil
    end
  end

  @doc """
  Assign the operator identity used by the drill-in gate: `:samen_operator_id` (the resolved
  acting operator id) and `:samen_operator_role` (kept if `Samen.Web.Operator.Authz` already
  assigned it from the host `:operator_authority` seam). Called from a drill-in `mount/3`
  after `assign_mount/2`.
  """
  @spec assign_identity(Phoenix.LiveView.Socket.t(), map(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_identity(socket, session, params) do
    principal = present(socket.assigns[:samen_operator_id]) || Auth.authenticated_user_id(session)

    socket
    |> Phoenix.Component.assign(:samen_operator_id, principal || resolve_operator_id(socket, session, params))
    |> Phoenix.Component.assign_new(:samen_operator_role, fn -> nil end)
  end

  @doc """
  The deny-on-read GATE for a per-tenant drill-in. Returns:

    * `{:ok, actor, session_info}` — an ACTIVE, unexpired, un-suspended impersonation session
      exists for `(operator_id, org_id)`. `actor` is the REAL impersonation-scope actor
      (`plane: :operator` + the REAL `session_id` marker, member-equivalent role, NO reveal
      grant → PII resolves `••••` by default). `session_info` is the tenant-ledger entry
      (who/why/expiry) for the active session, for the accountability line.
    * `:denied` — no active session (never opened / closed / expired mid-flight / operator
      suspended), a nil operator/org, or an unreachable impersonation repo. Fail closed.

  Rebuild this on EVERY request (mount + handle_params) so an expired session denies
  mid-flight — the kernel checks expiry per request, not per open.
  """
  @spec gate(String.t() | nil, String.t() | nil) ::
          {:ok, map(), map() | nil} | :denied
  def gate(operator_id, org_id) when is_binary(operator_id) and is_binary(org_id) do
    case Samen.Impersonation.scope(operator_id, org_id) do
      {:ok, %Samen.Scope{actor: actor}} ->
        {:ok, actor, active_entry(operator_id, org_id)}

      {:error, _reason} ->
        :denied
    end
  rescue
    _ -> :denied
  end

  def gate(_operator_id, _org_id), do: :denied

  @doc """
  Open an impersonation session for `(operator_id, org_id)` WITH A REQUIRED `reason` — the
  affordance the drill-in's denied state submits. Builds the `Samen.OperatorPlane.Actor` from
  the resolved operator id + role and delegates to `Samen.Impersonation.open/3` (reason
  required, same-tx audit + auto-expire enqueue, tenant-visible ledger). After a successful
  open the caller re-runs `gate/2` and renders masked.

  Refuses `{:error, :not_authorized}` when the role may not impersonate (`nil`, an unknown
  role, `:operator_readonly`) — fail closed.
  """
  @spec open(String.t() | nil, atom() | nil, String.t() | nil, String.t()) ::
          {:ok, Samen.Impersonation.Session.t()} | {:error, term}
  def open(operator_id, role, org_id, reason)
      when is_binary(operator_id) and is_binary(org_id) and role in @roles do
    Samen.Impersonation.open(Actor.new(operator_id, role), org_id, reason)
  end

  def open(_operator_id, _role, _org_id, _reason), do: {:error, :not_authorized}

  @doc """
  Open a session directly from a drill-in socket (its `:samen_operator_id` /
  `:samen_operator_role` / `:org_id` assigns) — the `handle_event("open_session", …)` helper.
  """
  @spec open_from_socket(Phoenix.LiveView.Socket.t(), String.t() | nil, String.t()) ::
          {:ok, Samen.Impersonation.Session.t()} | {:error, term}
  def open_from_socket(socket, org_id, reason) do
    open(socket.assigns[:samen_operator_id], socket.assigns[:samen_operator_role], org_id, reason)
  end

  @doc "The tenant-visible impersonation ledger for `org_id` (who/why/expiry). Delegates to the kernel."
  @spec ledger(String.t()) :: [map()]
  def ledger(org_id) when is_binary(org_id), do: Samen.Impersonation.list_for_org(org_id)
  def ledger(_), do: []

  @doc "The ACTIVE ledger entry for `(operator_id, org_id)` (the session driving this render), or nil."
  @spec active_entry(String.t(), String.t()) :: map() | nil
  def active_entry(operator_id, org_id) do
    org_id
    |> ledger()
    |> Enum.find(fn e -> e.operator_id == operator_id and e.active? end)
  rescue
    _ -> nil
  end

  defp present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      _ -> v
    end
  end

  defp present(_), do: nil
end
