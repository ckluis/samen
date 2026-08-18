defmodule Samen.Policy.FleetAdminOnly do
  @moduledoc """
  Default-deny policy admitting only `%Samen.Fleet.AdminActor{}` — the operator-
  gated fleet registry mutations (register/deregister an app, issue/revoke a
  credential, mint an enrollment token, record a directive). See
  `Samen.Fleet.AdminActor` for the placement note on why this is a narrow stand-in
  actor rather than a real role check (T83 wires the real `roles[:fleet] ==
  :operator_admin` gate at the web layer that mints this actor).
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor is the fleet-admin actor (kind: :fleet_admin) — default deny otherwise"
  end

  @impl true
  def match?(actor, _context, _opts) do
    Samen.Fleet.AdminActor.admin_actor?(actor)
  end
end
