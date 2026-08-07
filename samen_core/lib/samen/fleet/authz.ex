defmodule Samen.Fleet.Authz do
  @moduledoc """
  J3 — the FLEET-WIDE read of the host operator grant store (ADR-044 §6.2, §6.3a #1).

  ## One identity, N authorizations (§6.1)

  The fleet mints NO cross-product credential — a token that opened N operator planes
  would be exactly the skeleton key T146 exists to have eliminated. Authentication stays
  host-owned (ADR-031); the fleet only standardizes how AUTHORIZATION is expressed per
  product. `Samen.Web.Operator.Authz.resolve_role/2` already scopes a SINGLE product's
  role via the `:operator_authority` MFA whose `args` list is the product-scope carrier
  (`apply(mod, fun, args ++ [principal_id])`; the framework's own `dev_operator_role/2`
  already receives `[otp_app]` there). This module adds the **one new function J3 needs**:
  the fleet-wide read that answers "which products, and at what role, does THIS operator
  reach?" — used by the cockpit (T84) to decide which tiles it renders.

  ## The host seam — `:fleet_authority` (fail CLOSED)

  Grants are HOST-owned for the same reason authn is (ADR-031): the framework cannot know
  who your operators are. It is wired as an `{mod, fun, args}` MFA exactly like
  `:operator_authority`, called with the authenticated principal id APPENDED:

      config :my_app, :fleet_authority, {MyApp.Fleet.Auth, :fleet_roles, []}

  The resolver returns `%{scope => operator_role}` where `scope` is a product slug atom or
  the reserved atom `:fleet` (the cockpit itself). **Fail CLOSED** — no seam, an errored
  resolver, or any non-conforming return collapses to `%{}` (no cockpit, no tiles). The
  framework ships no default roster and no dev fallback beyond the existing, prod-armed
  fail-closed `Samen.Web.Operator.Authz.dev_operator_role/2` pattern. Each `{scope, role}`
  pair is validated: `scope` must be an atom and `role` a real
  `Samen.OperatorPlane.Actor` role — any entry failing this is DROPPED (mask-by-omission,
  ADR-028: a resolver bug fails toward LESS access, never more).

  Role isolation is a property of the SEAM, not of this reader: a role granted for product
  A appears only under `scope == A`; nothing in this map grants a capability in product B
  (RP-J-5). The reader never widens what the host returns.
  """

  alias Samen.OperatorPlane.Actor

  @roles Actor.roles()

  @typedoc "The reserved cockpit scope, or a product slug."
  @type scope :: :fleet | atom()

  @doc """
  The fleet-wide `%{scope => operator_role}` map the authenticated `principal_id` holds on
  the cockpit host `otp_app`, per the host `:fleet_authority` seam. Fail CLOSED to `%{}`:
  no seam, a non-MFA config, an erroring resolver, or a non-map return. Invalid entries
  (a non-atom scope or a non-role value) are dropped rather than admitted.
  """
  @spec roles_for(atom(), String.t() | nil) :: %{scope() => Actor.operator_role()}
  def roles_for(otp_app, principal_id) when is_atom(otp_app) do
    case Application.get_env(otp_app, :fleet_authority) do
      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        validate_map(apply(mod, fun, args ++ [principal_id]))

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  def roles_for(_otp_app, _principal_id), do: %{}

  # -- internals --------------------------------------------------------------

  defp validate_map(map) when is_map(map) do
    for {scope, role} <- map, is_atom(scope), role in @roles, into: %{}, do: {scope, role}
  end

  defp validate_map(_), do: %{}
end
