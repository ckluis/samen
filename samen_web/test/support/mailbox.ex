defmodule Samen.WebTest.Mailbox do
  @moduledoc """
  The samen_web test-support Mailbox domain — mounts the samen_core Mailbox scope
  blueprint (spec §I1, T74) exactly as a vertical would, giving `samen_web` its OWN
  materialized `Connection`/`MailMessage` resources to sync and render against in
  test. It is the REFERENCE ADOPTER for the scope: the whole adoption is the `use`
  line below (≈0 authored LOC — no resource, policy, matching, or masking code).

  Fresh `mwc`/`wmm` abbrevs reserved through the sanctioned allocator
  (`mix samen.abbrev.reserve --host samen_web`, ADR-023) — no samen_core change.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Mailbox,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Mailbox,
    abbrevs: %{connection: "mwc", mail_message: "wmm"}
end
