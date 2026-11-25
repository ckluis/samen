defmodule Samen.Policy.FilesUnderActorOrg do
  @moduledoc """
  Create-time check for the org ANCHOR (`Identity.Org`, which is org-less and so cannot use
  `Samen.Policy.OrgScope`): the new row's `org_id` — the org it is filed under — must equal the
  acting org. Used by `Org :open_account` (the operator console's "New account"), where `org_id` is
  the operator org that owns the account's book.

  Fail closed: no actor, no actor org, or a changeset without `org_id` is refused.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the row is filed under the actor's own org (new org_id == actor.org_id)"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    actor_org = if is_map(actor), do: Map.get(actor, :org_id)
    row_org = Ash.Changeset.get_attribute(changeset, :org_id)
    {:ok, not is_nil(actor_org) and not is_nil(row_org) and to_string(actor_org) == to_string(row_org)}
  end

  def match?(_actor, _context, _opts), do: {:ok, false}
end
