defmodule SamenCore.Support.CalendarFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **Calendar** scope (F2, T44) inside
  `samen_core`'s own test suite — mirrors `samen_core/test/support/work_fixture.ex`.

  Abbrev `sce` reserved via `mix samen.abbrev.reserve --host samen_core --propose`.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Calendar,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.CalendarFixture,
    abbrevs: %{event: "sce"}
end
