defmodule Samen.Fleet.AdminActor do
  @moduledoc """
  The principal `Samen.Fleet.Registry`'s operator-gated mutations (register/
  deregister/suspend an app, issue/revoke a credential, mint an enrollment token,
  record a published directive) run under.

  **Placement note (read before extending).** ADR-044 §6.3 assigns these
  capabilities to `roles[:fleet] == :operator_admin`, resolved via
  `Samen.Web.Operator.Authz` + the J3 args-carrier — **T83's** cross-product identity
  wiring, not built yet. T82 (this task) owns only the registry substrate; it cannot
  gate on a role model that does not exist yet. So this actor is the SAME shape as
  `Samen.Aggregate.Actor` was before T4.1's masked-impersonation actor existed: a
  narrow, named, single-purpose principal that stands in for "an operator_admin has
  already been authorized by the caller" — the CALLER (a future
  `Samen.Web.Operator.FleetRegisterLive`/`FleetDirectivesLive`, T83/T84) is
  responsible for checking `roles[:fleet] == :operator_admin` BEFORE minting one of
  these, exactly as every kernel action in this codebase that predates its own web
  authz layer is invoked by an already-authorized caller (e.g. `Samen.Auth.TokenMint`
  runs `authorize?: false` and trusts its caller).

  `Samen.Policy.FleetAdminOnly` is the ONE policy that admits it.
  """

  @enforce_keys [:principal_id]
  defstruct principal_id: nil, kind: :fleet_admin

  @type t :: %__MODULE__{principal_id: String.t(), kind: :fleet_admin}

  @doc "Mint a fleet-admin actor for `principal_id` (an already-authorized operator id)."
  @spec new(String.t()) :: t()
  def new(principal_id) when is_binary(principal_id),
    do: %__MODULE__{principal_id: principal_id, kind: :fleet_admin}

  @doc "Is this value the fleet-admin actor?"
  @spec admin_actor?(term()) :: boolean()
  def admin_actor?(%__MODULE__{}), do: true
  def admin_actor?(%{kind: :fleet_admin}), do: true
  def admin_actor?(_), do: false
end
