defmodule SamenCore.Support.WorkFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the **Work** scope (F1, ADR-041 §3, T43) inside
  `samen_core`'s own test suite — mirrors how `samen_core/test/support/archivable_fixture.ex`
  pilots the `archivable true` convention.

  Fresh abbrevs (`spw`/`stw`, reserved via `mix samen.abbrev.reserve --host samen_core
  --propose`) distinct from the `demo` host's `wpj`/`wtk` defaults — a scope's default
  abbrevs are claimed by its first real host mount (`demo`); this in-tree test fixture
  is a SECOND, distinct owner under the `samen_core` host namespace (mirrors how
  `driftwood`/`pawchart` take fresh Support abbrevs distinct from `demo`'s defaults).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Work,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.WorkFixture,
    abbrevs: %{project: "spw", task: "stw"}
end
