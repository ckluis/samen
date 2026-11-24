defmodule Samen.Policy.ManageUser do
  @moduledoc """
  The write rule for an identity `User` row (identity-authz review 3, B).

  `OrgScope` alone let any in-org actor, a viewer included, rewrite another user's handle, name
  and emails, suspend an admin, or reactivate itself. The rule, from the role model
  (`Samen.Scope.Role`) and the rule membership updates already use (`Samen.Policy.ManageRole`):

    * **update, own row** — a user edits their own profile fields. Their own `status` is not
      theirs to change (a suspended member could otherwise reactivate itself).
    * **update, another user's row, or any `status` change; destroy** — the actor must be at
      least `admin` AND strictly out-rank the target user's membership role in the actor's org
      (`Samen.Scope.Role.may_manage?/2`). The target's role is its highest-ranked membership
      there; a user with no membership counts as a `:viewer`. Nobody destroys themselves.

  Fail closed: a role lookup that errors is a denial. Options: `membership:` (the host's
  Membership resource module).
  """
  use Ash.Policy.SimpleCheck

  require Ash.Query

  @impl true
  def describe(_opts),
    do: "actor edits their own profile, or is an admin who strictly out-ranks the target user"

  @impl true
  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, opts) when is_map(actor) do
    target_id = changeset.data.id
    org_id = Map.get(actor, :org_id)
    actor_role = Map.get(actor, :role)
    own? = to_string(Map.get(actor, :id)) == to_string(target_id)

    cond do
      own? and changeset.action_type == :update and not Ash.Changeset.changing_attribute?(changeset, :status) ->
        {:ok, true}

      own? ->
        {:ok, false}

      true ->
        case target_role(Keyword.fetch!(opts, :membership), org_id, target_id) do
          {:ok, role} -> {:ok, Samen.Scope.Role.may_manage?(actor_role, role)}
          :error -> {:ok, false}
        end
    end
  end

  def match?(_actor, _context, _opts), do: {:ok, false}

  # The target's highest-ranked role in the actor's org (a membership-less user is a viewer).
  defp target_role(membership, org_id, user_id) when is_binary(org_id) do
    membership
    |> Ash.Query.filter(user_id == ^user_id and org_id == ^org_id)
    |> Ash.Query.select([:id, :role])
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, []} -> {:ok, :viewer}
      {:ok, rows} -> {:ok, rows |> Enum.map(& &1.role) |> Enum.max_by(&Samen.Scope.Role.rank/1)}
      {:error, _} -> :error
    end
  end

  defp target_role(_membership, _org_id, _user_id), do: :error
end
