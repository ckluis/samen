defmodule Samen.Fleet.Assignments do
  @moduledoc """
  The **minimal admin surface** for operator-account assignments (ADR-044 §16.5 #1,
  ruling R-A). Create / revoke / list the `(operator_id, app_scope, account_org_id)`
  grants `Samen.Fleet.Resolution.scope_from_assignments/4` reads.

  Every mutation and list here runs through the resource's `Ash.Policy.Authorizer`
  with the caller's operator actor, so `Samen.Policy.OperatorAdminOnly` gates them:
  only an `%Samen.OperatorPlane.Actor{operator_role: :operator_admin}` may manage
  assignments. A lower operator role, a tenant actor, or `nil` is refused
  (`{:error, ...}`) — fail-closed.

  Deliberately minimal (R-A): grant one, revoke one, list an operator's grants. No
  bulk import, no hierarchy, no delegation — speculative until asked. The product
  supplies its own mounted assignment resource module (e.g.
  `MyApp.OperatorScope.Assignment`).
  """

  @doc """
  Grant `operator_id` access to tenant account `account_org_id` in product
  `app_scope`. Idempotent on the `(operator_id, app_scope, account_org_id)` identity
  — re-granting an existing pair is not an error. Gated `:operator_admin`.
  """
  @spec grant(module(), String.t(), atom() | String.t(), String.t(), Samen.OperatorPlane.Actor.t()) ::
          {:ok, Ash.Resource.record()} | {:error, term()}
  def grant(resource, operator_id, app_scope, account_org_id, %Samen.OperatorPlane.Actor{} = admin)
      when is_atom(resource) and is_binary(operator_id) and is_binary(account_org_id) do
    resource
    |> Ash.Changeset.for_create(
      :create,
      %{operator_id: operator_id, app_scope: to_string(app_scope), account_org_id: account_org_id},
      actor: admin,
      upsert?: true,
      upsert_identity: :unique_grant
    )
    |> Ash.create()
  end

  def grant(_resource, _operator_id, _app_scope, _account_org_id, _actor),
    do: {:error, :not_authorized}

  @doc """
  Revoke a single `(operator_id, app_scope, account_org_id)` grant. A no-op `:ok` if
  the grant does not exist (idempotent). Gated `:operator_admin`.
  """
  @spec revoke(module(), String.t(), atom() | String.t(), String.t(), Samen.OperatorPlane.Actor.t()) ::
          :ok | {:error, term()}
  def revoke(resource, operator_id, app_scope, account_org_id, %Samen.OperatorPlane.Actor{} = admin)
      when is_atom(resource) and is_binary(operator_id) and is_binary(account_org_id) do
    with {:ok, rows} <- list(resource, operator_id, app_scope, admin) do
      rows
      |> Enum.filter(&(&1.account_org_id == account_org_id))
      |> Enum.reduce_while(:ok, fn row, :ok ->
        case Ash.destroy(row, actor: admin) do
          :ok -> {:cont, :ok}
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def revoke(_resource, _operator_id, _app_scope, _account_org_id, _actor),
    do: {:error, :not_authorized}

  @doc """
  List `operator_id`'s grants in `app_scope`. Gated `:operator_admin`. Returns
  `{:ok, [record]}` or `{:error, ...}` when the actor may not manage assignments.
  """
  @spec list(module(), String.t(), atom() | String.t(), Samen.OperatorPlane.Actor.t()) ::
          {:ok, [Ash.Resource.record()]} | {:error, term()}
  def list(resource, operator_id, app_scope, %Samen.OperatorPlane.Actor{} = admin)
      when is_atom(resource) and is_binary(operator_id) do
    app_scope_str = to_string(app_scope)

    require Ash.Query

    resource
    |> Ash.Query.filter(operator_id == ^operator_id and app_scope == ^app_scope_str)
    |> Ash.read(actor: admin)
  end

  def list(_resource, _operator_id, _app_scope, _actor), do: {:error, :not_authorized}
end
