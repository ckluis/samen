defmodule SamenCore.Support.LocationsFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **Locations** scope (F5, T47) inside
  `samen_core`'s own test suite — mirrors `test/support/docs_fixture.ex` /
  `test/support/tags_fixture.ex`.

  Fresh abbrev (`sll`, reserved via `mix samen.abbrev.reserve --host samen_core
  --owner SamenCore.Support.LocationsFixture.Location --propose`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Locations,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.LocationsFixture,
    abbrev: "sll"
end
