defmodule SamenCore.Support.DocsFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **Docs** scope (F3, T45) inside
  `samen_core`'s own test suite — mirrors `test/support/work_fixture.ex` and
  `test/support/calendar_fixture.ex`.

  Fresh abbrevs (`sdd`/`sdn`, reserved via `mix samen.abbrev.reserve --host
  samen_core --propose`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Docs,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.DocsFixture,
    abbrevs: %{doc: "sdd", note: "sdn"}
end
