defmodule SamenCore.Support.FleetFixture do
  @moduledoc """
  T82 (WS-J J1) — the `samen_core` own test-suite mount of the fleet registry
  blueprint (`Samen.Fleet.Scope`), exactly the `SamenCore.Support.MailboxFixture`/
  `OutreachFixture` precedent: a SECOND materialization of a library-authored
  blueprint inside samen_core's own test suite, so `fleet_registry_test.exs` /
  `reveal_fleet_refusal_test.exs` can prove `Samen.Fleet.Registry` reads/writes REAL
  `flt_*` rows through the real Ash/Postgres policy stack — not a mock.

  Fresh `sfa`/`sfc`/`sfe`/`sfr`/`sfd` abbrevs (reserved via `mix samen.abbrev.reserve
  --host samen_core --propose`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Fleet.Scope,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.FleetFixture,
    abbrevs: %{app: "sfa", credential: "sfc", enrollment_token: "sfe", report: "sfr", directive: "sfd"}
end
