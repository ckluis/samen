defmodule Samen.WebTest.Fleet do
  @moduledoc """
  T82 — the samen_web test-support mount of the fleet registry blueprint
  (`Samen.Fleet.Scope`), exactly the `Samen.WebTest.Mailbox` precedent: mounts the
  samen_core-authored blueprint into samen_web's OWN test repo, giving
  `fleet_ingress_test.exs` (HTTP-layer proof) a REAL `flt_*` table set through the
  full router/controller path, not a mock.

  Fresh `wfa`/`wfc`/`wfe`/`wfr`/`wfd` abbrevs reserved through the sanctioned
  allocator (`mix samen.abbrev.reserve --host samen_web`, ADR-023).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Fleet.Scope,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Fleet,
    abbrevs: %{app: "wfa", credential: "wfc", enrollment_token: "wfe", report: "wfr", directive: "wfd"}
end
