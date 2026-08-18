defmodule Demo.LocationsScope do
  @moduledoc """
  The Demo host's Locations domain — mounted from the `samen_core` Locations
  scope blueprint (ADR-004; F5, T47), mirroring `Demo.DocsScope`/`Demo.Tags`.

  One `use Samen.Scopes.Locations` expands into one host-owned resource
  (`Demo.LocationsScope.Location`), a normal `use Samen.Resource` in the
  DEMO's `otp_app`/`repo`, so:

    * its columns are catalogued in the DEMO's `tam_table`/`fld_field` (the
      `AddLocationsScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan it;
    * org-scope + RBAC policies are inherited, not re-authored;
    * `address` is 🔒 vault-routed (`vault: :pii_address`, the ADR-036 H4/c17
      composite) — masked per plane through the SAME `Samen.Api.PiiResolution`
      seam every other vaulted field uses (INV-1); no geometry column
      (ADR-037 §5.10).

  Demo stays API-only (per house layout) — no web-surface router mount here,
  same boundary as the Docs/Tags scopes.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Locations,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.LocationsScope,
    abbrev: "dll"
end
