defmodule SamenCore.Support.AgentMembershipFixture do
  @moduledoc """
  A test-only host seam for `Samen.AI.Agent.Approver` (ADR-047 A5 / the A4 verifier's
  R2): the `{module, function}` shape of the `approver_membership:` config key, backed by
  an in-memory membership table.

  `samen_core` mounts no `use Samen.Scopes.Identity` domain (Membership is materialized
  into a HOST's namespace — ADR-004), so the kernel suite exercises the seam through this
  fixture, while the REAL Ash-resource path is exercised in `samen_web` against
  `Samen.WebTest.Operator.Membership` (a genuine materialized Identity mount with a real
  table). Both directions of the fold are therefore proven on a real store.

  Deliberately NOT fail-open: an unregistered `{user, org}` answers `:error`, which the
  resolver turns into `{:error, :not_authorized}`.
  """

  @key {__MODULE__, :memberships}

  @doc "Register a membership: `user_id` is a member of `org_id` with `role`."
  def register(user_id, org_id, role \\ :member) do
    table = :persistent_term.get(@key, %{})

    :persistent_term.put(
      @key,
      Map.put(table, {user_id, org_id}, %{id: "mbs:" <> user_id, role: role})
    )

    :ok
  end

  @doc "Remove every registered membership."
  def reset, do: :persistent_term.put(@key, %{})

  @doc "The seam `Samen.AI.Agent.Approver` calls (arity 2)."
  def resolve(user_id, org_id) do
    case :persistent_term.get(@key, %{}) |> Map.get({user_id, org_id}) do
      nil -> :error
      membership -> {:ok, membership}
    end
  end

  @doc "Install this fixture as the approver-membership seam for the current test."
  def install! do
    prior = Application.get_env(:samen_core, Samen.AI.Agent, [])

    Application.put_env(
      :samen_core,
      Samen.AI.Agent,
      Keyword.put(prior, :approver_membership, {__MODULE__, :resolve})
    )

    prior
  end

  @doc "Restore the config captured by `install!/0`."
  def restore!(prior), do: Application.put_env(:samen_core, Samen.AI.Agent, prior)
end
