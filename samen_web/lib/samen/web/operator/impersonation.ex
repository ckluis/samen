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

    1. an explicit `operator_id` query param — **DEV-ONLY** (see below),
    2. an `operator_id` on the session (SERVER-set and signed, so it is trustworthy),
    3. the `:samen_operator_id` assign `Samen.Web.Operator.Authz` derived from the
       AUTHENTICATED session principal (the production path),
    4. the operator seat's well-known org id (`Samen.Web.Operator.org_id/1`) — a stable
       bounded id for the operator workspace, so a drill-in reached without an explicit
       principal (the disarmed dev dogfood) still has a consistent operator identity to open
       + gate a session under.

  Returns `nil` only when NONE resolves (no mount, no principal) → the gate denies.

  ## The `?operator_id` leg is dev-only (phase-6 SEC fix round, R1)

  Step 1 reads a CLIENT-CONTROLLED value. `assign_identity/3` already prefers the
  authenticated principal, so step 1 fires only when NO principal resolves at all — which a
  prod-armed host cannot reach, because `Samen.Web.Operator.Authz`'s `:require_operator`
  `on_mount` halts every non-operator before `mount/3` runs. That made the leg *unreachable*
  in prod but not *structurally dead*, and it was the mechanism behind the phase-6 dogfood
  H2 attribution forgery in the two vertical consoles (which had bypassed this function
  entirely and read the param FIRST, ahead of the principal).

  The leg is now gated on the SAME dev posture `Samen.Web.Operator.Authz.dev_operator_role/2`
  uses: it applies only while `auth_required?` is false for the drill-in mount's otp_app, and
  is inert the instant the app is armed for prod (`config otp_app, auth_required?: true`).
  A mount with no resolvable otp_app (an isolated component/unit test socket with no
  `:samen_mount`) is treated as disarmed, exactly as before — the framework routes always
  populate the mount, so every real armed deploy has the leg switched off.

  This is defence in depth, not the control: the control remains the `:require_operator`
  on_mount plus `assign_identity/3`'s principal-first order.
  """
  @spec resolve_operator_id(Phoenix.LiveView.Socket.t(), map(), map()) :: String.t() | nil
  def resolve_operator_id(socket, session \\ %{}, params \\ %{}) do
    dev_param_operator_id(socket, params) ||
      present(Map.get(session, "operator_id")) ||
      present(socket.assigns[:samen_operator_id]) ||
      operator_seat_id(socket)
  end

  defp dev_param_operator_id(socket, params) do
    if auth_disarmed?(socket), do: present(params["operator_id"]), else: nil
  end

  @doc """
  Is the drill-in socket's product UNARMED (dev/test posture, `auth_required?` false or
  unset)? The gate on the dev-only `?operator_id` leg of `resolve_operator_id/3`. A socket
  with no resolvable otp_app counts as unarmed (unit-test sockets carry no mount).
  """
  @spec auth_disarmed?(Phoenix.LiveView.Socket.t()) :: boolean()
  def auth_disarmed?(socket) do
    case Operator.otp_app(socket.assigns[:samen_mount]) do
      nil -> true
      otp_app -> not Samen.Web.TenantGate.armed?(otp_app)
    end
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
      exists for `(operator_id, org_id)` AND (when a product scope is configured) the account
      is IN the operator's scope. `actor` is the REAL impersonation-scope actor (`plane:
      :operator` + the REAL `session_id` marker, member-equivalent role, NO reveal grant → PII
      resolves `••••` by default). `session_info` is the tenant-ledger entry (who/why/expiry).
    * `:out_of_scope` — the R-B account-scope conjunct FAILED (§16.4a): the product wires a
      `:fleet_resolution` seam and `org_id ∉ scope_of(principal, app)`. Checked BEFORE the T150
      session, so a scoped-out operator is denied at the door and NEVER offered the
      open-session-with-reason form — opening a session must never be a way to *discover* you
      lack scope. The caller renders "this account is not in your scope", not the reason form.
    * `:denied` — in scope (or scope inert) but no active session (never opened / closed /
      expired mid-flight / operator suspended), a nil operator/org, or an unreachable repo.
      Fail closed. The caller renders the open-session-with-reason form.

  ## The R-B scope conjunct (ADR-044 §16.4a — the drill-in door)

  `may_drill_in? := T146 role AND (org_id ∈ scope_of/2) AND T150 session` — three ADDITIVE
  conjuncts, scope ADDED never substituting. T146 is enforced upstream (the `:require_operator`
  `on_mount` + the drill-in's own role check); this gate composes the SCOPE and T150 conjuncts.

  The scope test is KEYLESS `org_id` membership (`Samen.Fleet.Resolution.in_scope?/2`): the URL
  already carries the `org_id` and `scope_of/2` returns `org_id`s — no wire handle, no
  `fleet_subject_key` HMAC (that is the cockpit-side path only, §16.2).

  **`gate/3` is fleet-independent + no-lockout.** The scope conjunct engages ONLY when the
  product has a `:fleet_resolution` seam configured (`Resolution.configured?/1`). A product with
  NO seam — no fleet, a separately-deployed fleet, or a product that never adopted scoping —
  gets the pre-Amendment behaviour exactly (T146 + T150 only): `:all`-equivalent, never
  locked out of its OWN drill-ins. Cross-origin fleet unavailability is NOT a scope answer and
  never reaches this product-local gate (§16.2 boxed note). `gate/2` is `gate/3` with `nil`
  `otp_app` → scope permanently inert (the unchanged legacy call).

  Rebuild this on EVERY request (mount + handle_params) so an expired session — or a revoked
  assignment — denies mid-flight; the kernel + the scope seam are both re-read per request.
  """
  @spec gate(String.t() | nil, String.t() | nil) ::
          {:ok, map(), map() | nil} | :denied | :out_of_scope
  def gate(operator_id, org_id), do: gate(operator_id, org_id, nil)

  @spec gate(String.t() | nil, String.t() | nil, atom() | nil) ::
          {:ok, map(), map() | nil} | :denied | :out_of_scope
  def gate(operator_id, org_id, otp_app) when is_binary(operator_id) and is_binary(org_id) do
    # R-B scope conjunct FIRST (§16.4a ordering: scope before the reason form). When no
    # product scope is configured the conjunct is inert (no-lockout) and this is `false`.
    if scope_denied?(otp_app, operator_id, org_id) do
      :out_of_scope
    else
      case Samen.Impersonation.scope(operator_id, org_id) do
        {:ok, %Samen.Scope{actor: actor}} ->
          {:ok, actor, active_entry(operator_id, org_id)}

        {:error, _reason} ->
          :denied
      end
    end
  rescue
    _ -> :denied
  end

  def gate(_operator_id, _org_id, _otp_app), do: :denied

  @doc """
  `gate/3` with `otp_app` derived from the drill-in socket's mount (`Samen.Web.Operator.otp_app/1`)
  — the call every per-tenant drill-in LiveView uses so the R-B scope conjunct engages for the
  product the mount belongs to. Inert (identical to the pre-Amendment `gate/2`) for any product
  that wires no `:fleet_resolution` seam.
  """
  @spec gate_socket(Phoenix.LiveView.Socket.t(), String.t() | nil, String.t() | nil) ::
          {:ok, map(), map() | nil} | :denied | :out_of_scope
  def gate_socket(socket, operator_id, org_id) do
    gate(operator_id, org_id, Operator.otp_app(socket.assigns[:samen_mount]))
  end

  @doc """
  Is `(operator_id, org_id)` within the operator's account scope for this drill-in socket's
  product? `true` when the account is in scope OR no product scope is configured (inert /
  no-lockout). The R-B pre-check a drill-in open handler consults so a scoped-out open is
  refused before a session row is minted — independent of whether the open path keys on the
  same operator id as the gate.
  """
  @spec scope_ok?(Phoenix.LiveView.Socket.t(), String.t() | nil, String.t() | nil) :: boolean()
  def scope_ok?(socket, operator_id, org_id) when is_binary(operator_id) and is_binary(org_id) do
    not scope_denied?(Operator.otp_app(socket.assigns[:samen_mount]), operator_id, org_id)
  end

  def scope_ok?(_socket, _operator_id, _org_id), do: true

  # The R-B scope conjunct: the product wires a `:fleet_resolution` seam AND the account is
  # NOT in the operator's scope. Inert (`false`) whenever no seam is configured for `otp_app`
  # (the no-lockout / fleet-independent property, §16.4a). `scope_of/2` itself fails closed to
  # `:none` on any error, so a wired-but-erroring seam denies (mask-by-omission).
  defp scope_denied?(otp_app, operator_id, org_id) when is_atom(otp_app) and not is_nil(otp_app) do
    Samen.Fleet.Resolution.configured?(otp_app) and
      not Samen.Fleet.Resolution.in_scope?(
        Samen.Fleet.Resolution.scope_of(otp_app, operator_id),
        org_id
      )
  end

  defp scope_denied?(_otp_app, _operator_id, _org_id), do: false

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

  Belt-and-suspenders on the R-B scope conjunct: even though a scoped-out operator is never
  SHOWN the reason form (the gate returns `:out_of_scope` first), the `open_session` event is
  reachable via a crafted `phx-submit`, so scope is RE-CHECKED here — a scoped-out open is
  refused `{:error, :out_of_scope}` and no session row is ever minted (§16.4a: scope subtracts,
  never adds; opening a session is not a way to acquire scope). Inert when no product scope is
  configured (no-lockout).
  """
  @spec open_from_socket(Phoenix.LiveView.Socket.t(), String.t() | nil, String.t()) ::
          {:ok, Samen.Impersonation.Session.t()} | {:error, term}
  def open_from_socket(socket, org_id, reason) do
    operator_id = socket.assigns[:samen_operator_id]
    otp_app = Operator.otp_app(socket.assigns[:samen_mount])

    if is_binary(operator_id) and is_binary(org_id) and scope_denied?(otp_app, operator_id, org_id) do
      {:error, :out_of_scope}
    else
      open(operator_id, socket.assigns[:samen_operator_role], org_id, reason)
    end
  end

  @doc """
  The `%Samen.Scope{}` a drill-in passes to `Ash.read!(scope: …)` AFTER `gate/3` (or
  `gate_socket/3`) has APPROVED — built from the gate's OWN actor.

  The framework drill-ins read through `…Reads` helpers that take the actor directly; a
  vertical drill-in reads its own host resource with `Ash.read!(scope: scope)` and needs the
  `%Samen.Scope{}` wrapper. Before this helper existed the verticals got that scope by calling
  `Samen.Impersonation.scope/2` DIRECTLY — which made the kernel call the access DECISION and
  structurally skipped `gate/3`, so the §16.4a R-B account-scope conjunct could never engage at
  those doors (phase-6 dogfood M1, latent fail-open). Building the scope from the actor the gate
  already returned keeps ONE decision point: no second lookup that could disagree with the gate,
  and no path to a usable scope that did not pass through `gate/3`.

  The actor carries the REAL `imp_impersonation_session` marker (`plane: :operator`,
  member-equivalent role, no reveal grant), so the produced scope masks PII by construction
  exactly as `Samen.Impersonation.Scope.for_session/3`'s does — the marker is also mirrored into
  the scope context (ADR-040 §6.6) for `Samen.Audit.ImpersonationWrite`.
  """
  @spec read_scope(map()) :: Samen.Scope.t()
  def read_scope(actor) when is_map(actor) do
    case Map.get(actor, :impersonation) do
      %{} = marker -> %Samen.Scope{actor: actor, context: %{samen_impersonation: marker}}
      _ -> %Samen.Scope{actor: actor}
    end
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
