defmodule Driftwood.Primitives do
  @moduledoc """
  Driftwood's Primitives domain — the samen_core Primitives scope blueprint
  (ADR-004; `Samen.Scopes.Primitives`) mounted for the freight vertical, exactly
  as demo (`Demo.PrimitivesScope`) and the samen_web test host
  (`Samen.WebTest.Primitives`) mount it.

  WS-A A5 (inheritance proof): this mount exists so Driftwood INHERITS the
  framework notifications inbox (`Samen.Web.Notifications.{InboxLive,PreferencesLive}`,
  mounted by ONE `samen_notifications_routes` router line) — the sidebar
  "Notifications" nav item the framework `module_nav/1` already renders stops
  being a dead link. No Driftwood LiveView code is written for the inbox.

  Fresh `f*` abbrevs (the Driftwood convention — scope defaults `pnt/npr/pfl/psh/
  pwh/pff` are owned by the demo mount), reserved in
  `samen_core/priv/abbrev_registry.json` + mirrored in
  `driftwood/priv/abbrev_registry.json`:

    * `fnt` Notification (🔒 rendered_body → vault `:pii_body`; `pii_fnt_rendered_body`)
    * `fnp` NotificationPreference (no PII — bounded id + enums + bools)
    * `ffl`/`fsh`/`fwh`/`fff` — File/SearchIndex/Webhook/FeatureFlag (blueprint
      completeness; not yet surfaced in the Driftwood UI)

  The kernel notification ENGINE (`Samen.Notifications.Engine`) is wired to these
  resources in `config/config.exs` (notification_module/preference_module/repo +
  the samen_web PubSub broadcaster over `Driftwood.PubSub`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Primitives,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Primitives,
    abbrevs: %{
      notification: "fnt",
      notification_preference: "fnp",
      file: "ffl",
      search_index: "fsh",
      webhook: "fwh",
      feature_flag: "fff"
    }
end
