defmodule Samen.Identity.OneMembership do
  @moduledoc """
  `Identity.Membership` `:create`: a user holds ONE membership per org, so a create is refused when a row for that
  `(org_id, user_id)` already exists, whatever its role or status.

  Why it matters (identity-authz review 3, BLOCKER): `Samen.Auth.OrgActor.active_membership/3` resolves the LOWEST
  ranked active row, so an admin who could add a second, `:viewer` row for an owner (or a peer admin) demoted that
  member to viewer in every session, and the member could not remove the row (that needs admin+). Refusing the second
  row closes it at the source for every create path, `authorize?: false` ones included (registration, OIDC link,
  invitation accept and the operator seeds each create the user and its one membership together).

  The probe is a bare existence check over the whole table on the WRITE repo (the connection the caller's transaction
  is on, so a row written earlier in the same transaction is seen). It must see the row whatever the actor's org filter,
  and returns only a boolean refusal. A probe that cannot run refuses the write (fail closed): an unverifiable
  membership is not a free one.

  What this does NOT do: there is no unique index on `(org_id, user_id)` (that needs a migration), so two concurrent
  creates can still both pass. A database that ALREADY holds duplicates keeps resolving the lowest-ranked active row,
  which is the safe direction (the member never gains authority from a duplicate); those rows are not rewritten here.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _ctx) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)
      user_id = Ash.Changeset.get_attribute(changeset, :user_id)

      case exists?(changeset.resource, org_id, user_id) do
        {:ok, false} -> changeset
        {:ok, true} -> Ash.Changeset.add_error(changeset, field: :user_id, message: "already has a membership in this org")
        {:error, _} -> Ash.Changeset.add_error(changeset, field: :user_id, message: "could not be checked")
      end
    end)
  end

  @doc false
  @spec exists?(module(), term(), term()) :: {:ok, boolean()} | {:error, term()}
  def exists?(resource, org_id, user_id) do
    with true <- not is_nil(org_id) and not is_nil(user_id),
         {:ok, org} <- native(resource, :org_id, org_id),
         {:ok, user} <- native(resource, :user_id, user_id),
         repo when not is_nil(repo) <- AshPostgres.DataLayer.Info.repo(resource, :mutate),
         table when not is_nil(table) <- AshPostgres.DataLayer.Info.table(resource) do
      sql = "SELECT 1 FROM #{table} WHERE #{org.source} = $1 AND #{user.source} = $2 LIMIT 1"

      case repo.query(sql, [org.value, user.value]) do
        {:ok, %{rows: []}} -> {:ok, false}
        {:ok, %{rows: [_ | _]}} -> {:ok, true}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :unreadable}
    end
  end

  defp native(resource, name, value) do
    with %{type: type, constraints: constraints} = attr <- Ash.Resource.Info.attribute(resource, name),
         {:ok, dumped} <- Ash.Type.dump_to_native(type, value, constraints) do
      {:ok, %{source: to_string(attr.source || attr.name), value: dumped}}
    else
      _ -> :error
    end
  end
end
