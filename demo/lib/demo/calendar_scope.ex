defmodule Demo.CalendarScope do
  @moduledoc """
  The Demo host's Calendar domain — mounted from the `samen_core` Calendar
  scope blueprint (ADR-004; F2, T44), mirroring `Demo.WorkScope`.

  One `use Samen.Scopes.Calendar` expands into one host-owned resource
  (`Demo.CalendarScope.Event`), a normal `use Samen.Resource` in the DEMO's
  `otp_app`/`repo`, so:

    * its columns are catalogued in the DEMO's `tam_table`/`fld_field` (the
      `AddCalendarScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan it;
    * org-scope + RBAC policies are inherited, not re-authored;
    * `attendees` is 🔒 vault-routed (`vault: :pii_attendees`) — masked per
      plane through the SAME `Samen.Api.PiiResolution` seam every other
      vaulted field uses (INV-1).

  Demo stays API-only (per house layout) — no `samen_ics_routes` mount here;
  the `.ics` web surface is mounted on driftwood/pawchart only, same
  boundary as `samen_csv_routes`/the Work scope's web LiveViews.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Calendar,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.CalendarScope,
    abbrevs: %{event: "dce"}
end
