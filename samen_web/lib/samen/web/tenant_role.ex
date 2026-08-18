defmodule Samen.Web.TenantRole do
  @moduledoc """
  The TENANT-plane WRITE-role derivation (ADR-045 §4.4 — the S1a/S12 residual the B-SEC fix
  bounded but did not close). The tenant-plane twin of `Samen.Web.Operator.Authz.resolve_role/2`
  (T146): it answers "what admin-rank does the authenticated principal actually hold in this
  org?" from the SAME source of truth the settings surfaces already use — the principal's
  `Identity.Membership` row, via `Samen.Auth.OrgActor` (through `Samen.Web.CurrentOrg.resolve_actor/3`).

  ## The hole this closes (S1a)

  The tenant `write_scope/2` helpers (`Samen.Web.Flags.Reads`, `Samen.Web.Billing.Reads`,
  `Samen.Web.Marketing.Reads`, `Samen.Web.Support.KbReads`) unconditionally did
  `Map.put(actor, :role, :admin)` — so within an org ANY member performed admin-rank writes
  (toggle a flag, delete an invoice/plan/campaign, publish/archive a KB article). B-SEC closed
  the CROSS-tenant half (the `?org=` can no longer name another org on an armed host); this closes
  the INTRA-org half (a `:member` on an armed host no longer self-elevates to `:admin`).

  ## Three postures, strictly narrowing (never wider than the old unconditional `:admin`)

    1. **OPERATOR plane** (the operator flag-admin / impersonation write path) — keep `:admin`.
       That plane is authorized by T146 (`Samen.Web.Operator.Authz`) + T150
       (`Samen.Web.Operator.Impersonation.gate/3`), which re-derive from the session principal and
       re-check scope on every write. The elevation here is unchanged.
    2. **DISARMED tenant plane** (the sanctioned ADR-031 dev/dogfood posture) — keep `:admin`,
       BYTE-FOR-BYTE. `admin_scope/3` reduces to `Map.put(actor, :role, :admin)` exactly as the
       old helper did, so every existing dogfood test is untouched. This is the named
       `Samen.Web.Operator.Authz.dev_operator_role/2` convenience, tenant-side.
    3. **ARMED tenant plane** — the REAL `Identity.Membership` role (`membership_role/3`),
       fail-CLOSED to `:member` (least privilege, NEVER `:admin`) when there is no authenticated
       principal, no reachable Identity spine, or no membership row. So an armed host's admin-rank
       writes require ACTUAL admin membership; a non-admin member's write is refused by the kernel
       `RoleAtLeast :admin` gate.

  ## Reaching the Identity spine from a tenant MODULE mount

  `membership_role/3` reads `Identity.User`/`Identity.Membership` through `resolve_actor/3`, which
  derives those resources from the mount's namespace. A `:settings`/`:auth`-kind mount (and the
  generated `--live` screen's `@samen_authn_mount`) already carries the Identity namespace, so it
  is used directly. A tenant MODULE mount (crm/flags/billing/marketing/support) carries the
  VERTICAL namespace instead, so the host names the Identity namespace via the `:identity_namespace`
  label — the same sibling-mount seam `Samen.Web.Support.KbReads.kb_mount/1` uses for
  `:kb_namespace`. Absent the label the Identity read simply fails closed (`resolve_actor/3` rescues
  a non-resource module → `nil` → `:member`), so an armed module surface with no wired Identity seam
  is safe-because-DENIED, never safe-because-elevated.

  The masking model is untouched: this module reads/writes no vault field and never touches
  `actor.plane` — `Samen.Api.PiiResolution` remains the single clear-vs-`••••` decision.
  """

  alias Samen.Web.{CurrentOrg, Mount}

  @doc """
  The tenant-plane ADMIN write scope for `org_id` (the `write_scope/2` replacement). PRESERVES
  every plane marker (`plane`, `kind`, `impersonation`) from `Mount.scope/2` — the elevation
  raises RBAC rank only, never the masking plane, so `Samen.Pii.WriteGuard` still refuses a
  vaulted-PII write on the operator plane exactly as before. See the moduledoc for the three
  postures. `principal` is the authenticated principal id (credential/user) pinned by
  `Samen.Web.TenantAuthz`; `nil` fails closed on an armed tenant plane.
  """
  @spec admin_scope(Mount.t(), String.t(), String.t() | nil) :: Samen.Scope.t()
  def admin_scope(mount, org_id, principal \\ nil) do
    principal = principal || stashed_principal(mount)
    %Samen.Scope{actor: actor} = Mount.scope(mount, org_id)
    %Samen.Scope{actor: Map.put(actor, :role, role_for(mount, actor, org_id, principal))}
  end

  @doc """
  The label key under which `Samen.Web.Live.assign_mount/2` stashes the request's authenticated
  principal onto the mount, so the 2-arity `write_scope(mount, org_id)` helpers reach it with no
  per-call-site threading. Runtime-only (never serialized into the `live_session` session).
  """
  def principal_label, do: :__principal__

  defp stashed_principal(%Mount{} = mount), do: Mount.label(mount, :__principal__, nil)
  defp stashed_principal(_), do: nil

  # Operator plane → :admin (T146/T150-gated; unchanged). Tenant plane → the disarmed dev
  # convenience (:admin) or the armed membership-derived role (fail-closed :member).
  defp role_for(_mount, %{plane: :operator}, _org_id, _principal), do: :admin

  defp role_for(mount, _actor, org_id, principal) do
    if CurrentOrg.tenant_gate_armed?(mount),
      do: membership_role(mount, org_id, principal),
      else: :admin
  end

  @doc """
  The authenticated `principal`'s REAL role in `org_id`, read from `Identity.Membership` via the
  ONE source of truth (`Samen.Auth.OrgActor`, through `Samen.Web.CurrentOrg.resolve_actor/3`).
  Fail-CLOSED to `:member` (least privilege, NEVER `:admin`) when there is no principal, no
  reachable Identity spine (see the `:identity_namespace` seam in the moduledoc), or no membership
  row. Never raises.

  This is the tenant-plane analog of `Samen.Web.Operator.Authz.resolve_role/2`, and the helper the
  generated `--live` screens call to derive their acting role when the app is armed.
  """
  @spec membership_role(Mount.t() | nil, String.t() | nil, String.t() | nil) :: atom()
  def membership_role(mount, org_id, principal)
      when is_binary(org_id) and is_binary(principal) do
    case CurrentOrg.resolve_actor(mount, principal, org_id) do
      %{role: role} when is_atom(role) and not is_nil(role) -> role
      _ -> :member
    end
  end

  def membership_role(_mount, _org_id, _principal), do: :member
end
