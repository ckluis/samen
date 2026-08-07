defmodule Samen.Fleet.HeartbeatActor do
  @moduledoc """
  The heartbeat credential's resolved actor (ADR-044 §4.6) — capability EXACTLY
  `{fleet:heartbeat}`: append-only, one `app_id`, zero read.

  This is a distinct principal CLASS, not `%Samen.OperatorPlane.Actor{}`, not
  `%Samen.Scope{}`, and not `%Samen.Aggregate.Actor{}` — so it is refused by every
  authorizer already in the system:

    * `Samen.Policy.OrgScope` reads `actor.org_id`; this struct has none ⇒ filters to
      zero rows on any tenant-plane resource.
    * `Samen.Policy.AggregateActorOnly` matches only `Samen.Aggregate.Actor.aggregate?/1`
      ⇒ `false` here ⇒ refused.
    * `Samen.Web.Operator.Authz.resolve_role/2` has no grant-map entry for this kind
      ⇒ `nil` ⇒ `:halt`.
    * `Samen.Reveal.reveal/5` refuses it STRUCTURALLY (carried-LOW 1 — see
      `Samen.Reveal`'s fleet-actor cond clause, added by this task).

  `Samen.Policy.FleetIngressOnly` is the ONE policy that admits it, and admits it
  for exactly the two write actions the heartbeat/enroll ingress controllers call
  (`flt_report` create, the enroll-consume transaction) — never a read action.
  """

  @enforce_keys [:app_id]
  defstruct app_id: nil, kind: :fleet_heartbeat

  @type t :: %__MODULE__{app_id: String.t(), kind: :fleet_heartbeat}

  @doc "Mint the heartbeat actor for a resolved `app_id` (after credential verification)."
  @spec new(String.t()) :: t()
  def new(app_id) when is_binary(app_id), do: %__MODULE__{app_id: app_id, kind: :fleet_heartbeat}

  @doc "Is this value the fleet heartbeat actor?"
  @spec heartbeat_actor?(term()) :: boolean()
  def heartbeat_actor?(%__MODULE__{}), do: true
  def heartbeat_actor?(%{kind: :fleet_heartbeat}), do: true
  def heartbeat_actor?(_), do: false
end
