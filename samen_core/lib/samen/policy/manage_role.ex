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

  ## Both roles are checked (identity-authz review 3, #1)

  A write on an EXISTING row (update, destroy) must satisfy the rule against the role the row holds
  **in the database** AND, when the changeset sets one, the role being set. Checking only the new role let an
  `admin` demote or suspend an `owner` or a peer `admin` (setting `:member` is "strictly below" an admin).
  The stored role is read from the table by primary key on the WRITE repo (the connection the caller's
  transaction is on), never from the record in hand: that record may be stale, or carry
  `%Ash.NotLoaded{}` for `role`. A row that cannot be read is a denial (fail closed).

  A create has no stored row, so only the role being set counts. Because `may_manage?/2` is strict, an
  `owner` cannot demote, suspend or remove another `owner` either (`Samen.Scope.Role`: "no lateral
  escalation"): no update or destroy of an owner's membership passes this check. That is all it states: a write
  that does not go through this policy (`authorize?: false`, raw SQL, deleting the User or Org) is not covered, and a
  role set through `changeset.atomics` is refused outright because `get_attribute(:role)` cannot see it.

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
    actor_role = actor_role(actor)

    with :ok <- no_atomic_role(changeset),
         {:ok, stored} <- stored_role(changeset) do
      case stored do
        :none -> {:ok, new_role_ok?(changeset, actor_role)}
        stored -> {:ok, Samen.Scope.Role.may_manage?(actor_role, stored) and new_role_ok?(changeset, actor_role)}
      end
    end
  end

  # Non-changeset subjects (reads, action inputs) are not role escalations.
  def match?(_actor, _context, _opts), do: {:ok, true}

  # A role set through `changeset.atomics` (`Ash.Changeset.atomic_update(:role, expr)`) is invisible to
  # `get_attribute(:role)`, so it could not be held to the rule: refuse it by name (fail closed). The write the
  # policy sees is never one the check could not read.
  defp no_atomic_role(%Ash.Changeset{atomics: atomics}) do
    if Enum.any?(atomics || [], fn {name, _expr} -> name == :role end), do: {:error, :atomic_role}, else: :ok
  end

  # The role being SET (a create, or an update that changes it) must be strictly below the actor. A write that sets
  # none has nothing to escalate; the stored role was already held to the rule above.
  defp new_role_ok?(%Ash.Changeset{action_type: type} = changeset, actor_role) when type in [:create, :update] do
    case Ash.Changeset.get_attribute(changeset, :role) do
      nil -> true
      target -> type == :update and not Ash.Changeset.changing_attribute?(changeset, :role) or Samen.Scope.Role.may_manage?(actor_role, target)
    end
  end

  defp new_role_ok?(_changeset, _actor_role), do: true

  # `{:ok, :none}` — a create (no stored row). `{:ok, role}` — the role the row holds now. `{:error, _}` denies.
  defp stored_role(%Ash.Changeset{action_type: :create}), do: {:ok, :none}

  defp stored_role(%Ash.Changeset{resource: resource, data: data}) do
    with pk when pk != [] <- Ash.Resource.Info.primary_key(resource),
         {:ok, params} <- pk_params(resource, data, pk),
         repo when not is_nil(repo) <- AshPostgres.DataLayer.Info.repo(resource, :mutate),
         table when not is_nil(table) <- AshPostgres.DataLayer.Info.table(resource),
         role_src when not is_nil(role_src) <- source(resource, :role) do
      where =
        params
        |> Enum.with_index(1)
        |> Enum.map_join(" AND ", fn {{src, _}, i} -> "#{src} = $#{i}" end)

      case repo.query("SELECT #{role_src} FROM #{table} WHERE #{where} LIMIT 1", Enum.map(params, &elem(&1, 1))) do
        {:ok, %{rows: [[role]]}} when is_binary(role) ->
          if Samen.Scope.Role.valid?(role), do: {:ok, String.to_existing_atom(role)}, else: {:error, :unknown_role}

        {:ok, %{rows: []}} ->
          {:error, :unreadable}

        {:ok, _other} ->
          {:error, :unreadable}

        {:error, reason} ->
          {:error, {:unreadable, reason}}
      end
    else
      _ -> {:error, :unreadable}
    end
  end

  defp pk_params(resource, data, pk) do
    Enum.reduce_while(pk, {:ok, []}, fn name, {:ok, acc} ->
      attr = Ash.Resource.Info.attribute(resource, name)

      with value when not is_nil(value) <- Map.get(data, name),
           {:ok, dumped} <- Ash.Type.dump_to_native(attr.type, value, attr.constraints) do
        {:cont, {:ok, acc ++ [{source(resource, name), dumped}]}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      %{source: source} when not is_nil(source) -> to_string(source)
      %{name: n} -> to_string(n)
      _ -> nil
    end
  end

  defp actor_role(actor) when is_map(actor), do: Map.get(actor, :role)
  defp actor_role(_), do: nil
end
