defmodule Samen.Policy.FleetIngressOnly do
  @moduledoc """
  The **default-deny** policy for the fleet's credential-authenticated ingress
  writes (ADR-044 §4.6 — the `Samen.Policy.AggregateActorOnly` sibling this ADR
  adds).

  Admits ONLY `%Samen.Fleet.HeartbeatActor{}` (mirrors `AggregateActorOnly`'s shape
  exactly). Every other principal — a tenant scope, an operator-plane actor, the
  token-blind aggregate actor, the fleet-admin actor, an absent actor — is REFUSED.
  This is the structural half of ADR-044 §4.6's "the credential resolves to a
  `%Samen.Fleet.HeartbeatActor{}`, which is ... default-denied by every authorizer
  already in the system; the fleet adds `Samen.Policy.FleetIngressOnly` so it is
  also denied on fleet resources."

  ## Usage

      policies do
        policy always() do
          authorize_if Samen.Policy.FleetIngressOnly
        end
      end
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor is the fleet heartbeat credential actor (kind: :fleet_heartbeat) — default deny otherwise"
  end

  @impl true
  def match?(actor, _context, _opts) do
    Samen.Fleet.HeartbeatActor.heartbeat_actor?(actor)
  end
end
