defmodule Samen.OperatorPlane.Actor do
  @moduledoc """
  The **operator-plane actor** (T4.1 clause (a); doc §control "Running the business").

  Operator actors are a DISTINCT actor type — NOT tenant members. They run the
  business: an operator CRM where accounts ARE tenant orgs, ticketing over tenant
  support, cross-tenant billing rollups. Their RBAC is their own (`operator_role`),
  separate from the tenant `Samen.Scope.Role` set.

  ## Why a distinct type (not a tenant member with god-mode)

  The doc's two-planes idiom keeps the operator plane and the tenant plane as separate
  actors over the same objects. An operator is never "a member of every org" — that
  would collapse the boundary. Instead an operator holds ONE of a small operator-role
  set, and reaches a specific tenant org ONLY through a short-TTL impersonation session
  (`Samen.Impersonation`), never by carrying a tenant `org_id` ambiently.

  ## Operator roles (own RBAC)

    * `:operator_admin`   — can open impersonation sessions, read the operator CRM,
      manage operator-plane config.
    * `:operator_support` — can open impersonation sessions and read the operator CRM
      (the day-to-day support role).
    * `:operator_readonly`— read the operator CRM only; may NOT open impersonation
      sessions.

  These are deliberately NOT the tenant roles (`:owner/:admin/:member/:viewer`) — an
  operator is a different principal class. `may_impersonate?/1` gates who can open a
  session.

  ## The actor shape (what the operator plane sees)

    * `:id`            — the operator's id (opaque uuid) — bounded, never PII.
    * `:operator_role` — one of the operator-role set above.
    * `:kind`          — always `:operator` (marks the plane; the tenant plane never
      sets this, so a policy can tell them apart).

  No name/email/PII is placed on the operator actor — like the tenant actor, it is an
  authorization subject, not a profile (safe to log: bounded id + enum role).
  """

  @enforce_keys [:id, :operator_role]
  defstruct [:id, :operator_role, kind: :operator]

  @type operator_role :: :operator_admin | :operator_support | :operator_readonly

  @type t :: %__MODULE__{
          id: String.t(),
          operator_role: operator_role(),
          kind: :operator
        }

  @operator_roles [:operator_admin, :operator_support, :operator_readonly]

  @doc "The closed set of operator roles."
  @spec roles() :: [operator_role()]
  def roles, do: @operator_roles

  @doc """
  Build an operator actor. Raises if `operator_role` is not in the closed set (fail
  closed — an unknown role is refused rather than silently un-privileged, because an
  operator actor with a bogus role should never be minted).
  """
  @spec new(String.t(), operator_role()) :: t()
  def new(id, operator_role) when is_binary(id) and operator_role in @operator_roles do
    %__MODULE__{id: id, operator_role: operator_role}
  end

  def new(id, operator_role) do
    raise ArgumentError,
          "Samen.OperatorPlane.Actor.new/2 requires a binary id and one of " <>
            "#{inspect(@operator_roles)}. Got id=#{inspect(id)}, role=#{inspect(operator_role)}"
  end

  @doc """
  May this operator open an impersonation session? `:operator_admin` and
  `:operator_support` may; `:operator_readonly` may NOT. Any non-operator actor
  (e.g. a tenant member) may NOT — impersonation is an operator-plane capability.
  """
  @spec may_impersonate?(t() | term()) :: boolean()
  def may_impersonate?(%__MODULE__{operator_role: role}),
    do: role in [:operator_admin, :operator_support]

  def may_impersonate?(_), do: false

  @doc "Is this value an operator-plane actor?"
  @spec operator?(term()) :: boolean()
  def operator?(%__MODULE__{}), do: true
  def operator?(%{kind: :operator}), do: true
  def operator?(_), do: false
end
