defmodule Samen.Policy.OrgIsSelf do
  @moduledoc """
  The org-anchor policy check (T3.1) — for the `org` resource itself, which is
  org-LESS (it IS the tenant boundary, so it has no foreign `org_id` to filter on).

  A `FilterCheck` that authorizes a row only when the row's own `id` equals the
  actor's `org_id`. So an actor scoped to org A may read/update/destroy only org A's
  own row — never another org's. This is the `Samen.Policy.OrgScope` analogue for the
  anchor: `OrgScope` filters `org_id == actor.org_id` (for members of an org);
  `OrgIsSelf` filters `id == actor.org_id` (for the org row itself).

  Kept as a named check (rather than an inline `expr` in the blueprint) because the
  blueprint defines resources inside a `quote`, where an inline `expr(id == ...)`
  would be hygiene-captured. A `FilterCheck` module is context-free and composes
  cleanly into any scope's blueprint.

  Fail closed: an actor with no `org_id` matches no rows (`expr(false)`).
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts), do: "org.id == actor.org_id (org anchor self-scope)"

  @impl true
  def filter(actor, _context, _opts) do
    case actor_org_id(actor) do
      nil -> expr(false)
      org_id -> expr(id == ^org_id)
    end
  end

  @impl true
  def reject(actor, _context, _opts) do
    case actor_org_id(actor) do
      nil -> expr(true)
      org_id -> expr(id != ^org_id or is_nil(id))
    end
  end

  defp actor_org_id(actor) when is_map(actor), do: Map.get(actor, :org_id)
  defp actor_org_id(_), do: nil
end
