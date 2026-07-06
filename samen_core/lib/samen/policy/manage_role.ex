defmodule Samen.Policy.ManageRole do
  @moduledoc """
  The **no-escalation** RBAC check (T3.1; the `role escalation denied` red path).

  A `SimpleCheck` for create/update of a role-bearing row (membership, role). It
  authorizes only when the acting actor may *manage* the role the changeset is
  setting — i.e. `Samen.Scope.Role.may_manage?(actor.role, target_role)`.

  The rule (`Samen.Scope.Role.may_manage?/2`): the actor must be at least `admin`
  AND strictly out-rank the target role. So:

    * a `member` minting an `admin` membership → **denied** (member < admin);
    * an `admin` minting an `owner` membership → **denied** (no lateral/upward);
    * an `admin` minting a `member` → allowed;
    * an `owner` minting an `admin` → allowed.

  ## Reading the target role from the changeset

  On a create/update the target role is the `:role` attribute the changeset is
  setting (defaults to the row's current value on update, `:member` fallback on
  create). If no role is being set, this check is a no-op pass (the row's role is
  unchanged — nothing to escalate).

  ## Why a second check beyond `RoleAtLeast`

  `RoleAtLeast(role: :admin)` gates *who may touch* memberships; `ManageRole` gates
  *what role they may set*. Both are needed: an admin may edit memberships
  (`RoleAtLeast`), but must not set one to `owner` (`ManageRole`). Together they are
  the escalation guard.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts) do
    "actor may manage the role being set (no privilege escalation)"
  end

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    case target_role(changeset) do
      # No role change requested → nothing to escalate. Pass (other policies still
      # gate the write; this check is only about escalation).
      nil -> {:ok, true}
      target -> {:ok, Samen.Scope.Role.may_manage?(actor_role(actor), target)}
    end
  end

  # Non-changeset subjects (reads, action inputs) are not role escalations.
  def match?(_actor, _context, _opts), do: {:ok, true}

  defp target_role(changeset) do
    Ash.Changeset.get_attribute(changeset, :role)
  end

  defp actor_role(actor) when is_map(actor), do: Map.get(actor, :role)
  defp actor_role(_), do: nil
end
