defmodule Samen.Policy.OwnerOnly do
  @moduledoc """
  The canonical **per-user owner-scope** policy check (G10 saved views, T58) — the
  per-user sibling of `Samen.Policy.OrgScope`.

  Where `OrgScope` narrows every tenant-plane read/write to the acting ORG, `OwnerOnly`
  narrows a PER-USER resource (a saved view, a personal preference) to the acting USER:
  it is an `Ash.Policy.FilterCheck` keyed on the row's `owner_id` and the actor's `id`.
  On a read it makes ANOTHER user's rows **not exist** (`[]`, no existence oracle); on a
  write it authorizes only when the row's `owner_id` equals the actor's `id` (a create
  spoofing a foreign `owner_id`, or an update/destroy of a foreign row, is refused).

  ## Stacking with OrgScope (the two-axis isolation)

  A per-user resource stacks BOTH checks, each in its own `policy` block, so the
  FilterChecks **AND** together into one row filter:

      policies do
        policy action_type(:read) do
          authorize_if Samen.Policy.OrgScope    # org axis: cross-org rows do not exist
        end

        policy action_type(:read) do
          authorize_if Samen.Policy.OwnerOnly   # user axis: another user's rows do not exist
        end
      end

  Cross-ORG isolation and cross-USER isolation are therefore BOTH enforced by
  construction: an actor scoped to (org A, user 1) reads only rows where
  `org_id == A AND owner_id == 1`.

  ## Actor contract

  Reads `actor.id` (the acting user's id — the `%Samen.Scope{}` actor map, see
  `Samen.Scope`). If the actor has no `id`, the filter is `false` — **no rows** (fail
  closed), mirroring `OrgScope`'s org-less posture. Because the samen_web tenant plane's
  default actor id is a synthetic per-ORG broker id (`"broker:<org_id>"`, not a per-user
  identity), a per-user consumer must build a scope whose `actor.id` is the REAL current
  user id (see `Samen.Web.SavedViews.owner_scope/3`) before this check is meaningful.
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts) do
    "record.owner_id == actor.id (per-user owner-scope isolation)"
  end

  @impl true
  def filter(actor, _context, _opts) do
    case actor_id(actor) do
      nil ->
        # No user id on the actor → no rows. Fail closed: an identity-less caller must
        # not see any per-user row.
        expr(false)

      id ->
        expr(owner_id == ^id)
    end
  end

  # The reject (negative) filter: rows this actor may NOT touch. Explicit so the
  # postgres NULL semantics are correct (mirrors OrgScope) — a NULL owner_id is never
  # this actor's row.
  @impl true
  def reject(actor, _context, _opts) do
    case actor_id(actor) do
      nil -> expr(true)
      id -> expr(owner_id != ^id or is_nil(owner_id))
    end
  end

  defp actor_id(actor) when is_map(actor), do: Map.get(actor, :id)
  defp actor_id(_), do: nil
end
