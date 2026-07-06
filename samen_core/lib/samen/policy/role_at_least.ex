defmodule Samen.Policy.RoleAtLeast do
  @moduledoc """
  The canonical **RBAC rank** policy check (T3.1; doc scope table `role`).

  A `SimpleCheck` that authorizes only when the actor's role rank is at least the
  required role. Rank comes from `Samen.Scope.Role`. Reads `actor.role`.

  ## Usage

      policies do
        # only admins+ may create/alter memberships or roles
        policy action_type([:create, :update, :destroy]) do
          authorize_if {Samen.Policy.RoleAtLeast, role: :admin}
        end
      end

  Fail closed: an actor with no role, or an unknown role, ranks below every real
  role → denied. This is half of the `role escalation denied` red path (the other
  half — a `member` cannot mint an `admin` — is `Samen.Policy.ManageRole`, which
  also checks the *target* rank).
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts) do
    "actor.role rank >= #{inspect(opts[:role])}"
  end

  @impl true
  def match?(actor, _context, opts) do
    required = Keyword.fetch!(opts, :role)
    Samen.Scope.Role.at_least?(actor_role(actor), required)
  end

  defp actor_role(actor) when is_map(actor), do: Map.get(actor, :role)
  defp actor_role(_), do: nil
end
