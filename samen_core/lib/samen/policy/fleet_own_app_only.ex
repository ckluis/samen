defmodule Samen.Policy.FleetOwnAppOnly do
  @moduledoc """
  ADR-044 §4.6 capability-matrix row: *"valid heartbeat key, `POST /fleet/heartbeat`
  (other app_id in body) ⇒ `403`; own app_id ⇒ `204`"*. A `FilterCheck` narrowing a
  `%Samen.Fleet.HeartbeatActor{}`'s write to rows whose `app_id` equals the actor's
  OWN `app_id` — the STRUCTURAL half of the "one app_id, zero read" capability set
  (`Samen.Policy.FleetIngressOnly` proves the actor CLASS; this proves the actor
  cannot even write another app's row under its own class).

  Stacks with `Samen.Policy.FleetIngressOnly` in its own `policy` block on
  `flt_report`'s create action, exactly like `Samen.Policy.OwnerOnly` stacks with
  `OrgScope` — both FilterChecks AND together into one row/changeset predicate.
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "record.app_id == actor.app_id (fleet heartbeat own-app-only)"

  # Stacks in its OWN policy block (ANDed with every other block on the action),
  # so it must be a PASS-THROUGH (never restrictive) for any actor that is not a
  # `%Samen.Fleet.HeartbeatActor{}` — otherwise it would also narrow the
  # fleet-admin write path, which carries no `app_id` at all. Only a heartbeat
  # actor is restricted; everyone else is unaffected by this dimension.
  @impl true
  def filter(actor, _context, _opts) do
    case actor_app_id(actor) do
      nil -> expr(true)
      app_id -> expr(app_id == ^app_id)
    end
  end

  @impl true
  def reject(actor, _context, _opts) do
    case actor_app_id(actor) do
      nil -> expr(false)
      app_id -> expr(app_id != ^app_id or is_nil(app_id))
    end
  end

  defp actor_app_id(%Samen.Fleet.HeartbeatActor{app_id: app_id}), do: app_id
  defp actor_app_id(_), do: nil
end
