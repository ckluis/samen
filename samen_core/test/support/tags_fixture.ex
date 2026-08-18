defmodule SamenCore.Support.TagsFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **Tags** scope (F4, T46) inside
  `samen_core`'s own test suite — mirrors `test/support/docs_fixture.ex`.

  Fresh abbrevs (`stt`/`tst`, reserved via `mix samen.abbrev.reserve --host
  samen_core --propose`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Tags,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.TagsFixture,
    abbrevs: %{tag: "stt", tagging: "tst"}
end
