defmodule PawChart.Primitives do
  @moduledoc """
  PawChart's Primitives domain — the samen_core Primitives scope blueprint
  (ADR-004; `Samen.Scopes.Primitives`) mounted for the vet vertical, exactly as
  demo (`Demo.PrimitivesScope`) and Driftwood (`Driftwood.Primitives`) mount it.

  WS-A A5 (inheritance proof): this mount exists so PawChart INHERITS the framework
  notifications inbox (`Samen.Web.Notifications.{InboxLive,PreferencesLive}`,
  mounted by ONE `samen_notifications_routes` router line) — the sidebar
  "Notifications" nav item the framework `module_nav/1` already renders stops being
  a dead link. Zero PawChart LiveView code.

  Fresh `v*` abbrevs (the PawChart vet convention — scope defaults `pnt/npr/pfl/
  psh/pwh/pff` are owned by the demo mount), reserved in
  `samen_core/priv/abbrev_registry.json`:

    * `vnt` Notification (🔒 rendered_body → vault `:pii_body`; `pii_vnt_rendered_body`)
    * `vnp` NotificationPreference (no PII — bounded id + enums + bools)
    * `vfl`/`vsh`/`vwh`/`vff` — File/SearchIndex/Webhook/FeatureFlag (blueprint
      completeness; not yet surfaced in the PawChart UI)

  The kernel notification ENGINE (`Samen.Notifications.Engine`) is wired to these
  resources in `config/config.exs` (notification_module/preference_module/repo +
  the samen_web PubSub broadcaster over `PawChart.PubSub`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Primitives,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Primitives,
    abbrevs: %{
      notification: "vnt",
      notification_preference: "vnp",
      file: "vfl",
      search_index: "vsh",
      webhook: "vwh",
      feature_flag: "vff"
    }
end
