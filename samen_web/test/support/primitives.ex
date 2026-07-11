defmodule Samen.WebTest.Primitives do
  @moduledoc """
  The samen_web test-support PRIMITIVES domain (WS-A A4 UNIT 2) — mounts the samen_core
  Primitives scope blueprint (ADR-004; `Samen.Scopes.Primitives`) exactly as demo does,
  giving `samen_web` its OWN materialized `Notification` + `NotificationPreference`
  resources so the framework notifications inbox (`Samen.Web.Notifications.InboxLive`)
  renders against a real vault-routed record in test — with NO dependency on any vertical.

  Fresh `wn*` abbrevs, appended to `samen_core/priv/abbrev_registry.json` (append-only
  rows for the test host — the sanctioned kernel touch, ADR-006/ADR-009 §6):

    * `wnn` Notification (🔒 rendered_body → vault `:pii_body`; `pii_wnn_rendered_body`)
    * `wnp` NotificationPreference (no PII — bounded id + enums + bools)
    * `wnf`/`wns`/`wnw`/`wng` — File/SearchIndex/Webhook/FeatureFlag (blueprint
      completeness; unused by the inbox tests)

  The namespace root is `Samen.WebTest`, so a notification's `subject_ref`
  (`samen:crm.person:<id>`) unfurls through `Samen.Web.ObjectRef.Catalog` to
  `Samen.WebTest.Crm.Person` — the SAME host the CRM render tests read.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Primitives,
    otp_app: :samen_web,
    repo: Samen.WebTest.Repo,
    namespace: Samen.WebTest.Primitives,
    abbrevs: %{
      notification: "wnn",
      notification_preference: "wnp",
      file: "wnf",
      search_index: "wns",
      webhook: "wnw",
      feature_flag: "wng"
    }
end
