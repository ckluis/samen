defmodule Samen.Web.Plane do
  @moduledoc """
  Which of the TWO planes a mounted `samen_web` module is rendering on (ADR-009 §5).

  The thesis: the SAME module renders the **tenant plane** (an org acting over its OWN
  data, PII in the clear) vs the **operator plane** (the SaaS company acting, whose
  accounts ARE the tenant orgs, PII masked `••••`).

  ## Masking is BY CONSTRUCTION — the plane masks nothing itself

  The plane does not decide what to hide. It produces the **actor** (`scope/2`), and the
  actor's `:plane` key is what `Samen.Api.PiiResolution` reads (`plane_of/1`). The resolver
  returns `%Samen.Masked{}` on the operator plane because the session carries no reveal
  grant — a `%Masked{}` renders `••••` via `Phoenix.HTML.Safe`. No LiveView has a masking
  branch; the plane cannot produce plaintext on the operator path because the resolver
  won't. This is the ADR-008 invariant generalized to the framework.

  ## The two kinds

    * `:tenant`   — the org acts over its own data. Actor `plane: :tenant`. PII CLEAR
      (the tenant-as-owner rule — an org reads its own PII with no reveal grant).
    * `:operator` — the SaaS company acts; a tenant org IS its account. The operator opens
      ONE tenant via an impersonation session (`Samen.Impersonation`, T4.1) and reads that
      tenant's REAL CRM/Billing/Support UI with PII present-but-masked (`••••`). Actor
      `plane: :operator` + `kind: :operator` + `impersonation: %{...}`.
  """
  @enforce_keys [:kind]
  defstruct [:kind, :operator_id, :target_org_id, :impersonation]

  @type t :: %__MODULE__{
          kind: :tenant | :operator,
          operator_id: String.t() | nil,
          target_org_id: String.t() | nil,
          impersonation: map() | nil
        }

  @doc "A tenant plane (the default — an org over its own data)."
  def tenant, do: %__MODULE__{kind: :tenant}

  @doc """
  An operator plane over a single target tenant org (masked impersonation).
  `operator_id` identifies the acting operator; `target_org_id` is the tenant org
  being opened. Optional `session_id` records the REAL `imp_impersonation_session`
  id backing this plane.

  T150: this NO LONGER fabricates a synthetic `"operator-session"` id when none is
  given — an operator-plane scope with no real session carries `session_id: nil`
  (honest: it references no `imp_impersonation_session` row). The per-tenant drill-in
  surfaces do not read through this plane at all anymore: they gate on a real session
  via `Samen.Web.Operator.Impersonation.gate/2` (deny-on-read) and build their scope
  from `Samen.Impersonation.scope/3`, which carries the REAL session id. The marker
  key stays present so `Samen.Api.PiiResolution`'s impersonation posture (masked-but-
  PRESENT `••••`) still holds for the operator-plane masking unit tests.
  """
  def operator(operator_id, target_org_id, session_id \\ nil) do
    %__MODULE__{
      kind: :operator,
      operator_id: operator_id,
      target_org_id: target_org_id,
      impersonation: %{session_id: session_id}
    }
  end

  @doc """
  Build the `%Samen.Scope{}` for reading a host's resources on this plane.

  `org_id` is the tenant org whose data is being read (for the operator plane this is the
  target tenant org, which the caller may also carry in `target_org_id`). The produced
  actor is exactly the one the driftwood-local LiveViews built inline (`crm_scope/1` /
  `operator_scope/1`), promoted here so no LiveView reinvents it.

    * `:tenant`   → actor with `kind: :tenant, plane: :tenant` → resolver reveals CLEAR.
    * `:operator` → actor with `kind: :operator, plane: :operator, impersonation: %{...}`
      → resolver's impersonation branch returns `%Masked{}` (→ `••••`).
  """
  @spec scope(t(), String.t() | nil) :: Samen.Scope.t()
  def scope(%__MODULE__{kind: :tenant}, org_id) do
    %Samen.Scope{
      actor: %{
        id: "broker:#{org_id}",
        org_id: org_id,
        role: :member,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  def scope(%__MODULE__{kind: :operator} = plane, org_id) do
    target = plane.target_org_id || org_id
    operator_id = plane.operator_id || "operator"

    %Samen.Scope{
      actor: %{
        id: "operator:#{operator_id}",
        org_id: target,
        role: :member,
        kind: :operator,
        plane: :operator,
        impersonation: plane.impersonation || %{session_id: nil}
      }
    }
  end

  @doc "Serialize the plane to a session-safe map (only atoms/strings; no PII)."
  def to_session(%__MODULE__{} = p) do
    %{
      "kind" => Atom.to_string(p.kind),
      "operator_id" => p.operator_id,
      "target_org_id" => p.target_org_id,
      "session_id" => p.impersonation && Map.get(p.impersonation, :session_id)
    }
  end

  @doc "Rebuild a plane from its session map."
  def from_session(%{"kind" => "operator"} = m) do
    %__MODULE__{
      kind: :operator,
      operator_id: m["operator_id"],
      target_org_id: m["target_org_id"],
      impersonation: %{session_id: m["session_id"]}
    }
  end

  def from_session(_), do: %__MODULE__{kind: :tenant}
end
