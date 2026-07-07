defmodule Samen.Policy.AggregateActorOnly do
  @moduledoc """
  The **default-deny** policy for the token-blind aggregate plane (T4.2 clause (a);
  doc §control "an aggregate actor with no org_id reading a vault-excluded
  projection").

  A `SimpleCheck` that authorizes ONLY the singleton `Samen.Aggregate.Actor`
  (`kind: :operator_aggregate`). Every other principal — a tenant `%Samen.Scope{}`
  actor, an operator-plane impersonation actor (`kind: :operator`), an api_key
  actor, an org-less/actor-less request — is REFUSED.

  This is one half of the **mutual exclusion** the doc stakes:

    * The aggregate actor is the ONLY actor the aggregate domain's policies admit
      (this check). A tenant / impersonation / reveal-class actor reading the
      aggregate domain denies (T4.2 red path: a tenant actor reading the aggregate
      domain denies).

  The other half lives on the tenant plane and the reveal seam:

    * `Samen.Policy.OrgScope` reads `actor.org_id`; the aggregate actor has none, so
      it filters to ZERO rows — the aggregate actor is refused by every tenant-plane
      resource by construction (T4.2 red path: aggregate actor reading a
      tenant-plane resource denies).
    * `Samen.Reveal.reveal/5` refuses an `:operator_aggregate` actor structurally
      (T4.2 mutual-exclusion: aggregate ⟂ reveal).

  ## Usage (in an aggregate-domain resource's `policies do` block)

      policies do
        # DEFAULT DENY. Only the token-blind aggregate actor is admitted.
        policy always() do
          authorize_if Samen.Policy.AggregateActorOnly
        end
      end

  Because this is the only `authorize_if` and Ash policies default to forbid, a
  request whose actor is not the aggregate actor is denied (there is no `authorize_if
  always()` fallthrough). Fail closed: an unknown/absent actor is refused.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor is the token-blind aggregate actor (kind: :operator_aggregate) — default deny otherwise"
  end

  @impl true
  def match?(actor, _context, _opts) do
    Samen.Aggregate.Actor.aggregate?(actor)
  end
end
