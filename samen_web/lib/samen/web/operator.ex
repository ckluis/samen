defmodule Samen.Web.Operator do
  @moduledoc """
  The operator / SaaS-company control-plane context (ADR-010). The SaaS company is ITSELF an
  org — the OPERATOR ORG — running the same universal scopes, whose accounts/customers/
  requesters ARE the tenant orgs.

  This context resolves the well-known operator org id and builds the operator-org
  TENANT-PLANE scope. That is the identity-line hinge: the operator reads its OWN book of
  business (tenant orgs as accounts, tenant-admins as contacts) on the tenant plane, so that
  PII is CLEAR — the SaaS owns it. The tenant's DOWNSTREAM end-customer PII stays masked,
  reachable only via the ADR-009 impersonation plane (`Samen.Web.Plane.operator/3`), which
  this context does NOT change.

  ## The identity line is the composition of two kernel primitives (ADR-010 §5.2)

    * `Samen.Policy.OrgScope` filters WHICH rows: the operator-org actor sees only the
      operator org's OWN rows (its accounts, its billing customers, its desk tickets).
    * `Samen.Api.PiiResolution` decides CLEAR vs `••••`: `plane: :tenant` clears own-org PII
      with no reveal grant.

  Compose them and population (1) — the SaaS's own book of business, tenant-admins included —
  is clear by construction, with NO new plaintext path. Population (2) — a tenant's downstream
  end-customers — is the EXISTING `plane: :operator` impersonation path, masked. This module
  only names the operator org and builds its tenant-plane scope; it adds no masking code.

  ## The operator seat's PII plane is `:tenant` (of the operator org), NOT `:operator`

  Subtle and load-bearing (ADR-010 §7.2): "operator plane" in ADR-009 meant *impersonating a
  tenant, masked*. The operator's OWN control-plane workspace is the operator org on ITS OWN
  tenant plane (clear). The word "operator" names the ORG and the WORKSPACE; the PII PLANE for
  that workspace is `:tenant`. Only the drill-into-a-tenant action uses `plane: :operator`
  (masked). `scope/1` therefore always produces the operator org on the TENANT plane.
  """

  alias Samen.Web.{Mount, Plane}

  @doc """
  The operator org id for a mount. Resolution order (ADR-010 §3.1):

    1. the mount's `:operator_org_id` label (explicit),
    2. `Application.get_env(otp_app, :operator_org_id)`,
    3. the single seeded row in the operator namespace's `Org` table.

  The `otp_app` for step 2 is read from the mount's repo config (`repo.config()[:otp_app]`),
  falling back to a `:otp_app` label if present. Step 3 reads the operator namespace's `Org`
  resource with an unauthenticated read (the operator org is the well-known anchor; the seed
  guarantees exactly one row) and returns its id.
  """
  @spec org_id(Mount.t()) :: String.t() | nil
  def org_id(%Mount{} = mount) do
    explicit_label(mount) || from_app_env(mount) || from_single_org_row(mount)
  end

  @doc """
  The operator-org TENANT-PLANE scope. The operator acts as an org OVER ITS OWN vendor data:
  `%{org_id: operator_org_id, plane: :tenant}`. `OrgScope` narrows every read to the operator
  org's rows; `plane: :tenant` reveals the operator's OWN customers' PII (the tenant-admins) in
  the clear. This is population (1) of the identity line — clear by construction.

  Deliberately reuses `Plane.tenant()` — the exact tenant-plane actor ADR-009 already tests —
  so the identity-line clarity for population (1) is inherited verbatim, no new actor shape.

  ## A3 plane-awareness (fail-MASKED, never fail-clear)

  The framework router only ever mounts the operator workspace on the TENANT plane
  (`samen_operator_routes`, §7.2) — the clause above is the whole story for every real
  route. But the operator pages now render PII (the desk requester, the account admins)
  AND carry write affordances, so a HAND-CRAFTED mount that carries `plane: :operator`
  (an impersonation plane) must not silently fall back to the clear tenant plane: if the
  mount says "operator plane", the scope IS the operator plane — `PiiResolution` masks
  (`%Masked{}` → `••••`) and `Samen.Pii.WriteGuard` refuses vaulted writes. The odd
  mount fails MASKED, never clear. This adds no new actor shape either — it is the
  EXISTING ADR-009 operator-plane actor, built by the same `Plane.scope/2`.
  """
  @spec scope(Mount.t()) :: Samen.Scope.t()
  def scope(%Mount{plane: %Plane{kind: :operator} = plane} = mount),
    do: Plane.scope(plane, org_id(mount))

  def scope(%Mount{} = mount), do: Plane.scope(Plane.tenant(), org_id(mount))

  @doc """
  The `Samen.Web.Plane.operator/3` plane for drilling INTO a tenant's downstream world from an
  account (ADR-010 §3.3 — the impersonation bridge). Crossing from the clear account (this
  operator org's own row) to the masked tenant world is exactly this deliberate step; the
  resulting plane is `:operator` (masked), the EXISTING ADR-009 path — unchanged here.

  `tenant_org_id` is the account row's back-reference (the tenant org's real id in the vertical
  namespace). Returns a `Samen.Web.Plane` suitable for a vertical-namespace mount.
  """
  @spec impersonation_plane(Mount.t(), String.t(), String.t() | nil) :: Plane.t()
  def impersonation_plane(%Mount{} = mount, tenant_org_id, session_id \\ nil) do
    Plane.operator(org_id(mount) || "operator", tenant_org_id, session_id)
  end

  @doc """
  The host `otp_app` this operator mount belongs to — read from an explicit `:otp_app`
  label, else derived from the mount repo's config (`repo.config()[:otp_app]`). `nil`
  when neither resolves.

  Public so the R-B drill-in scope gate (`Samen.Web.Operator.Impersonation`) can read
  the product's `:fleet_resolution` seam for the SAME app the mount belongs to — the
  scope is product-local and fleet-independent (ADR-044 §16.4a).
  """
  @spec otp_app(Mount.t()) :: atom() | nil
  def otp_app(%Mount{} = mount) do
    Mount.label(mount, :otp_app, nil) || repo_otp_app(mount)
  end

  def otp_app(_), do: nil

  # -- resolution steps --------------------------------------------------------

  defp explicit_label(%Mount{} = mount), do: Mount.label(mount, :operator_org_id, nil)

  defp from_app_env(%Mount{} = mount) do
    case otp_app(mount) do
      nil -> nil
      app -> Application.get_env(app, :operator_org_id)
    end
  end

  defp repo_otp_app(%Mount{repo: repo}) when is_atom(repo) do
    if function_exported?(repo, :config, 0) do
      repo.config()[:otp_app]
    end
  rescue
    _ -> nil
  end

  defp repo_otp_app(_), do: nil

  # The operator org is the well-known anchor; the seed guarantees exactly one Org row in the
  # operator namespace. Read it org-lessly (the Org anchor create/read is bootstrap-friendly)
  # and take the single row's id. Fail-safe: any error → nil (the LiveView shows "no org").
  defp from_single_org_row(%Mount{} = mount) do
    Mount.resource(mount, Org)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.limit(1)
    # authz-scope: operator-namespace anchor bootstrap — this read DISCOVERS the
    # operator org id, so it cannot be org_id-pinned (chicken-and-egg); the operator
    # namespace holds exactly one Org by seed invariant, `limit(1)` takes that anchor,
    # Org carries no PII. Operator plane only (T132).
    |> Ash.read!(authorize?: false)
    |> case do
      [%{id: id} | _] -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
