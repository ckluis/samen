defmodule Samen.Policy.MinterRoleCeiling do
  @moduledoc """
  The api-key **no-escalation** check: a key's `minter_role` — the authority the key
  acts with at use time (`Samen.Scope.ApiKey` actor ceiling) — may never outrank the
  actor minting it.

  `Samen.Policy.ManageRole` is the wrong shape for this: it requires the actor to
  STRICTLY out-rank the target (an admin can't grant admin), whereas an admin minting
  a key that acts as an admin is the normal case. The rule here is `actor.role >=
  minter_role`, fail closed: a missing, unknown or out-of-set `minter_role` is refused
  (a role-less key authorizes nothing and must not be mintable), and so is an actor
  with no role.
  """
  use Ash.Policy.SimpleCheck

  alias Samen.Scope.Role

  @impl true
  def describe(_opts), do: "the key's minter_role does not outrank the acting role"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    target = Ash.Changeset.get_attribute(changeset, :minter_role)
    {:ok, Role.valid?(target) and Role.at_least?(actor_role(actor), target)}
  end

  def match?(_actor, _context, _opts), do: {:ok, false}

  defp actor_role(actor) when is_map(actor), do: Map.get(actor, :role)
  defp actor_role(_), do: nil
end
