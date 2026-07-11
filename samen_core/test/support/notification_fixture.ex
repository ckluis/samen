defmodule SamenCore.Support.NotificationFixture do
  @moduledoc """
  Kernel fixture for the notifications engine (WS-A A4 UNIT 1; ADR-016 §4). Mounts
  the Primitives scope under a dedicated `ne*` abbrev set so the engine's record +
  preference-aware dispatch can be exercised against a REAL Postgres DB in
  `samen_core` — without touching the demo/driftwood/pawchart hosts.

  The two load-bearing resources:

    * `NotificationFixture.Notification` (abbrev `nen`) — `rendered_body` is
      vault-routed (`pii_nen_rendered_body` holds a `vt_*` token). The engine writes
      through this resource, so the PII rule (object refs + non-PII copy only; no
      denormalized plaintext) is proven end-to-end.
    * `NotificationFixture.NotificationPreference` (abbrev `nep`) — the per-recipient
      opt-out the engine consults BEFORE writing a record (the suppressed-event red
      path).

  Like `SamenCore.Support.SuppressionFixture`, this domain is deliberately NOT in
  `:ash_domains` (kept out of the CI verifier/catalog sweeps). Its vault-routed
  `pii_nen_rendered_body` column is therefore allow-listed for `vault_declared_parity`
  in `config/test.exs` — the route IS declared, just not on a registered domain.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Primitives,
    otp_app: :samen_core,
    repo: SamenCore.TestRepo,
    namespace: SamenCore.Support.NotificationFixture,
    abbrevs: %{
      notification: "nen",
      notification_preference: "nep",
      file: "nef",
      search_index: "nes",
      webhook: "nwh",
      feature_flag: "ngf"
    }
end
