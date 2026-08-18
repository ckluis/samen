defmodule SamenCore.Support.OutreachFixture do
  @moduledoc """
  Kernel test-fixture domain mounting the REAL **Outreach** scope blueprint
  (`Samen.Scopes.Outreach`, spec §I2, T75) inside `samen_core`'s own test suite —
  the reference materialization `samen_core/test/crm/sequence_send_test.exs`
  exercises end to end against a real Postgres DB.

  Fresh `sos`/`soe`/`sso` abbrevs (reserved via `mix samen.abbrev.reserve --host
  samen_core --propose`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Outreach,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.OutreachFixture,
    abbrevs: %{sequence: "sos", enrollment: "soe", step_send: "sso"}
end
