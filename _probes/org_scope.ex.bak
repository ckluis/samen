defmodule Samen.Policy.OrgScope do
  @moduledoc """
  The canonical **org-scope** policy check (T3.1; doc §runs 1 org-scope idiom).

  This is the single most-copied policy in the foundry: *every tenant-plane read and
  write is filtered by the acting org.* It is an `Ash.Policy.FilterCheck` — so on a
  read it narrows the result set to `org_id == actor.org_id` (rows from other orgs
  are invisible, not merely forbidden), and on a write it authorizes only when the
  row's `org_id` equals the actor's.

  ## Why a FilterCheck (not a SimpleCheck)

  A `forbid`-style check on cross-org access leaks existence (a 403 tells the caller
  the row exists). A FilterCheck makes foreign-org rows **not exist** for this actor
  — a cross-org read returns `[]`, the correct multi-tenant semantics. This is the
  mechanism behind the `cross-org read denied` red-path property test: for any two
  distinct orgs, an actor scoped to org A reading a resource returns zero of org B's
  rows.

  ## Actor contract

  Reads `actor.org_id` (the `%Samen.Scope{}` actor map, see `Samen.Scope`). If the
  actor has no `org_id`, the filter is `false` — **no rows** (fail closed). An
  unauthenticated/org-less caller sees nothing on the tenant plane.

  ## Usage (in a resource's `policies do` block)

      policies do
        policy action_type([:read, :create, :update, :destroy]) do
          authorize_if Samen.Policy.OrgScope
        end
      end

  The scope-authoring guide (§3) makes every tenant-plane resource copy exactly this
  block. Resources that are org-less by nature (the `org` anchor itself) use the
  membership-scoped variant instead (see the guide).
  """
  use Ash.Policy.FilterCheck

  @impl true
  def describe(_opts) do
    "record.org_id == actor.org_id (org-scope tenant isolation)"
  end

  @impl true
  def filter(actor, _context, _opts) do
    case actor_org_id(actor) do
      nil ->
        # No org on the actor → no rows. Fail closed: an org-less caller must not
        # see any tenant-plane row.
        expr(false)

      org_id ->
        expr(org_id == ^org_id)
    end
  end

  # The reject (negative) filter: rows this actor may NOT touch. Explicit so the
  # postgres NULL semantics are correct (see FilterCheck moduledoc) — the opposite
  # of `org_id == ^org_id` must also match rows whose org_id is NULL.
  @impl true
  def reject(actor, _context, _opts) do
    case actor_org_id(actor) do
      nil -> expr(true)
      org_id -> expr(org_id != ^org_id or is_nil(org_id))
    end
  end

  defp actor_org_id(actor) when is_map(actor), do: Map.get(actor, :org_id)
  defp actor_org_id(_), do: nil
end
