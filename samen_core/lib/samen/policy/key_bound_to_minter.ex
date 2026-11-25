defmodule Samen.Policy.KeyBoundToMinter do
  @moduledoc """
  The api-key **identity binding** check: a key created through an authorized actor must be
  bound to THAT actor's own membership, and its `minter_role` may not exceed that membership's
  CURRENT role.

  `Samen.Policy.SameOrgFk` only proves the membership is in the same org, and
  `Samen.Policy.MinterRoleCeiling` only compares `minter_role` with the actor's role. Neither
  stops an admin creating a key whose `membership_id` is the OWNER's membership: at use time the
  key's requests carry `actor.id = membership.user_id`, so the audit trail and every `actor.id`
  policy (`Samen.Policy.OwnerOnly`) would treat the key as the owner.

  Refused (fail closed) unless ALL hold:

    * the `membership_id` names an existing membership;
    * `membership.user_id == actor.id`;
    * the membership is `"active"`;
    * `membership.role >= minter_role` (the role the membership holds NOW, not the actor's claim).

  The membership row is read with a bare repo query (not an `Ash.read`), like
  `Samen.Policy.SameOrgFk`, so no policy hides it from the check that must see it. System and
  seed paths that attribute a key to someone else do so with `authorize?: false` — the only way.
  """
  use Ash.Policy.SimpleCheck

  alias Samen.Scope.Role

  @impl true
  def describe(_opts), do: "the key is bound to the actor's own active membership, and its minter_role does not outrank it"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    membership_id = Ash.Changeset.get_attribute(changeset, :membership_id)
    minter_role = Ash.Changeset.get_attribute(changeset, :minter_role)

    with true <- is_map(actor) and not is_nil(Map.get(actor, :id)),
         true <- not is_nil(membership_id),
         {:ok, row} <- Samen.Scope.ApiKey.membership_row(changeset.resource, membership_id) do
      {:ok,
       to_string(row.user_id) == to_string(Map.get(actor, :id)) and
         row.status == "active" and
         Role.valid?(minter_role) and Role.at_least?(row.role, minter_role)}
    else
      _ -> {:ok, false}
    end
  end

  def match?(_actor, _context, _opts), do: {:ok, false}
end
