defmodule Samen.WebTest.OperatorScope.Resolver do
  @moduledoc """
  T84 test-support `:fleet_resolution` resolver — the reference glue a real host wires
  behind its `config :my_app, :fleet_resolution, {…}` seam. Composes the operator's role
  (here a per-test roster in app env, in production the `:operator_authority` resolver)
  with the assignment resource via `Samen.Fleet.Resolution.scope_from_assignments/4`.

  Wired per-test as `{Samen.WebTest.OperatorScope.Resolver, :scope, [:samen_web]}` — the
  `:samen_web` arg is the J3 product-scope carrier; the principal id is appended by
  `Samen.Fleet.Resolution.scope_of/2`.
  """

  @doc "The account scope `principal_id` holds on product `app_scope`."
  @spec scope(atom(), String.t() | nil) :: Samen.Fleet.Resolution.scope()
  def scope(app_scope, principal_id) do
    role = Application.get_env(:samen_web, :test_operator_roles, %{})[principal_id]

    Samen.Fleet.Resolution.scope_from_assignments(
      Samen.WebTest.OperatorScope.Assignment,
      role,
      app_scope,
      principal_id
    )
  end
end
