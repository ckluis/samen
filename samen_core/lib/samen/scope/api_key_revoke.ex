defmodule Samen.Scope.ApiKey.RevokeOnce do
  @moduledoc """
  Resource change for an api key's `:revoke` action: `revoked_at` becomes
  `if is_nil(revoked_at), do: now, else: revoked_at` IN THE UPDATE STATEMENT.

  The previous in-Elixir test (`is_nil(changeset.data.revoked_at)`) trusted the record in hand: a row
  read with a `select` that omitted `revoked_at` carries `%Ash.NotLoaded{}`, `is_nil/1` of that is
  false, nothing was set, and `:revoke` answered `{:ok, row}` with the key still live — a security
  action failing OPEN. Here the decision is made by the database from the stored value, so it never
  depends on what was loaded, a second revoke keeps the ORIGINAL instant, and two concurrent revokes
  agree on one instant.
  """
  use Ash.Resource.Change

  require Ash.Expr

  @impl true
  def change(changeset, _opts, _ctx) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Ash.Changeset.atomic_update(
      changeset,
      :revoked_at,
      Ash.Expr.expr(if is_nil(revoked_at), do: ^now, else: revoked_at)
    )
  end
end
