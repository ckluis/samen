defmodule Samen.WebTest.Outreach do
  @moduledoc """
  The samen_web test-support Outreach domain — mounts the samen_core Outreach scope
  blueprint (spec §I2 CRM sequences actually send, T75) exactly as a vertical would,
  giving `samen_web` its OWN materialized `Sequence`/`Enrollment`/`StepSend` resources
  to enroll into and render against in test. It is the REFERENCE ADOPTER for the scope
  on the web plane: the whole adoption is the `use` line below (≈0 authored LOC — no
  resource, policy, send-path, or masking code re-authored), the SAME shape
  `Samen.WebTest.Mailbox` adopts the Mailbox scope.

  Fresh `wso`/`woe`/`ows` abbrevs reserved through the sanctioned allocator
  (`mix samen.abbrev.reserve --host samen_web --propose`, ADR-023) — no samen_core change.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Outreach,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Outreach,
    abbrevs: %{sequence: "wso", enrollment: "woe", step_send: "ows"}
end
