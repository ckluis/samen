defmodule Samen.Policy.OperatorConsoleWrite do
  @moduledoc """
  Create-time check for the org anchor's operator-only write (`Identity.Org :open_account`): the changeset must
  carry `context: %{samen_operator_write: true}`.

  ## What this is, and what it is not

  The operator console acts through the plane's synthetic `:member` scope (`Samen.Web.Plane.scope/2`), so a
  resource policy cannot see the AUTHENTICATED operator role (`:operator_admin | :operator_support |
  :operator_readonly`): that role lives in the LiveView's `:samen_operator_role` assign
  (`Samen.Web.Operator.Authz`). The console therefore checks the role FIRST (`Authz.write_role?/1`) and only then
  builds the form with this flag. The flag is not a credential: it stops a TENANT actor (viewer, member, admin of
  any org) from calling `:open_account` directly with its own org id and any plan, which nothing else in the
  resource refused. Host code that sets it asserts "I checked the operator role"; code that can set it can already
  call `authorize?: false`.

  Fail closed: a missing context, any other value, or a changeset-less request is refused.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the operator console set context.samen_operator_write after checking the operator write role"

  @impl true
  def match?(_actor, %{changeset: %Ash.Changeset{context: %{samen_operator_write: true}}}, _opts), do: {:ok, true}
  def match?(_actor, _context, _opts), do: {:ok, false}
end
