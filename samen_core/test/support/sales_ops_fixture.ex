defmodule SamenCore.Support.SalesOpsFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **SalesOps** scope (F6+F7, T48) inside
  `samen_core`'s own test suite — mirrors `test/support/locations_fixture.ex` /
  `test/support/docs_fixture.ex`. `Lead.convert` targets
  `SamenCore.Support.CrmScopeFixture.{Person,Opportunity,Company}` — the real
  `Samen.Scopes.Crm` blueprint mounted alongside this fixture.

  Fresh abbrevs (`ssv`/`sls`, reserved via `mix samen.abbrev.reserve --host
  samen_core --propose`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.SalesOps,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.SalesOpsFixture,
    person_mod: SamenCore.Support.CrmScopeFixture.Person,
    opportunity_mod: SamenCore.Support.CrmScopeFixture.Opportunity,
    company_mod: SamenCore.Support.CrmScopeFixture.Company,
    abbrevs: %{vendor: "ssv", lead: "sls"}
end
