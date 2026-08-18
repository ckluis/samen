defmodule Samen.Scopes.Locations do
  @moduledoc """
  The **Locations** universal scope (F5; spec §F5, spec-questions c17). Ships as a
  **library-authored blueprint** (ADR-004), same shape as
  `Samen.Scopes.Work`/`Samen.Scopes.Docs`/`Samen.Scopes.Tags`: `use`-ing this module
  inside a host's Ash domain expands into ONE host-owned resource in the host's
  namespace, a normal `use Samen.Resource` with the host's `otp_app`, `repo`, and
  `domain`.

  ## Resource — `location`

  - **`Location`** — a physical-place-centric record (a site, office, warehouse, etc.)
    for verticals that need one: `name` + `address` (the ADR-036 H4 composite
    `Samen.Type.Address`, ALWAYS vaulted — `vault: :pii_address`). Archivable
    (ADR-040 §5.9).

  ## Split per c17 (ADR-036 H4 vs F5)

  ADR-036/T14 (DONE) delivers the `Samen.Type.Address` composite TYPE + the
  `pii_address` vault-class recipe (`pii_attribute :address, Samen.Type.Address,
  vault: :pii_address`). This scope (F5, T47) is the separate deliverable that
  *USES* that type on a real resource — it adds no new type, no new vault
  mechanism, just the Location resource declaring the same recipe T14 already
  proved (see `SamenCore.Support.RichTypes.PersonalFixture` / `Samen.Type.AddressTest`).

  ## No geometry column (ADR-037 §5.10 — binding, T47 named)

  `ash_geo` is REJECTED (dormant dependency, zero spec requirement for spatial
  queries — M4 already settled the map view on server-side SVG tiles, not
  PostGIS). Location carries **no latitude/longitude/geometry column** — just the
  postal `Samen.Type.Address` composite. The documented extension seam for a
  vertical that DOES need spatial queries (geo 4.x + geo_postgis + a custom
  `Ash.Type`) is recorded in ADR-037 §5.10, deliberately not built here.

  ## PII map (INV-1)

  `address` is the ONLY PII-bearing attribute — a vaulted `Samen.Type.Address`
  composite (`vault: :pii_address`), masked per plane through the standard
  `Samen.Api.PiiResolution` seam every other vaulted field uses (never
  hand-masked). `name` is plain (an operator-authored label for the place, e.g.
  "Springfield Warehouse" — not itself subject PII).

  ## No object-ref attachment (unlike Docs/Tags)

  Spec F5 does not ask Location to be attachable to arbitrary objects the way
  Doc/Note/Tagging are — Location is the *target* other resources will FK or
  object-ref-anchor to in a future consumer (mirroring how Docs/Tags anchor TO
  a CRM person/ticket/etc.), not an anchor itself. So this scope carries no
  `subject_key`/`subject_id` pair and needs no samen_web write-helper layer —
  the INV-1 3-proof lives entirely at this samen_core scope-test layer
  (`samen_core/test/locations_scope_test.exs`), mirroring
  `Samen.Type.AddressTest`'s own MaskingCase 3-proof applied to a real resource.

  ## Mounting the Locations scope (the host side)

      defmodule Demo.LocationsScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Locations,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.LocationsScope
      end

  This defines, in the host's namespace:

    * `Demo.LocationsScope.Location`

  ## Abbrevs (permanent, registry-checked)

  Single resource per host, reserved via `mix samen.abbrev.reserve` (ADR-023 — the
  macro does NOT invent abbrevs). No scope-default — every host takes a fresh
  allocator-proposed abbrev, passed via `abbrevs:`:

    * `SamenCore.Support.LocationsFixture.Location` → `sll`
    * `Demo.LocationsScope.Location`                 → `dll`
    * `Driftwood.Locations.Location`                 → `fll` (driftwood's initial
      proposal collided cross-host with demo's `dll` — the SAME "host-name-blind
      proposer" collision class T44/T45/T46 each hit for Calendar/Docs/Tags — so
      driftwood took `fll` instead, mirroring the established f-prefix
      collision-avoidance convention)
    * `PawChart.Locations.Location`                  → `pll`

  No samen_web mount — Location has no web-specific feature this task ships
  (unlike Calendar's ICS export or Docs'/Tags' object-ref attach helper).
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrev = Keyword.fetch!(opts, :abbrev) |> Macro.expand(__CALLER__)

    location_mod = Module.concat(namespace, Location)

    quote do
      require Samen.Scopes.Locations.Blueprint

      resources do
        resource(unquote(location_mod))
      end

      Samen.Scopes.Locations.Blueprint.define_location(
        unquote(location_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrev)
      )
    end
  end
end
