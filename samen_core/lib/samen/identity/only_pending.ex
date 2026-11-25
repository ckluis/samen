defmodule Samen.Identity.OnlyPending do
  @moduledoc """
  Invitation `:revoke` change: the update applies only to a row that is STILL `status == "pending"` in the
  database. The in-memory `validate` on the action refuses early from the struct in hand, but a read-then-write
  can lose the race: an accept that commits between `Invite.revoke`'s read and its update would be relabelled
  "revoked" while the membership already exists (an audit-truth problem). The filter rides in the UPDATE
  statement, so a stale struct matches zero rows and the update fails (`Ash.Error.Changes.StaleRecord`); accept
  and expire are untouched.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.filter(changeset, Ash.Expr.expr(status == "pending"))
  end
end
