defmodule Samen.Policy.OperatorAdminOnly do
  @moduledoc """
  Default-deny policy admitting only an `%Samen.OperatorPlane.Actor{}` whose
  `operator_role` is `:operator_admin`.

  The minimal admin surface for the operator-account assignment resource (ADR-044
  §16.5 #1, ruling R-A): only an operator-admin may create/revoke/list assignments.
  Every other actor — a lower operator role (`:operator_support`/`:operator_readonly`
  /`:operator_break_glass`), a tenant-plane actor, the impersonation actor, or a
  fleet actor — is denied. Fail-closed: a `nil` or non-operator actor never matches.

  This is deliberately distinct from `Samen.Policy.FleetAdminOnly` (which admits the
  narrow `%Samen.Fleet.AdminActor{}` stand-in for registry mutations). Assignment
  management is a REAL operator-role check, not a stand-in — the operator identity is
  the authenticated principal resolved through `Samen.Web.Operator.Authz`.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor is an operator-plane actor with operator_role :operator_admin — default deny otherwise"
  end

  @impl true
  def match?(%Samen.OperatorPlane.Actor{operator_role: :operator_admin}, _context, _opts), do: true
  def match?(_actor, _context, _opts), do: false
end
