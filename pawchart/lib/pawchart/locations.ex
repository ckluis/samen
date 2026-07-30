defmodule PawChart.Locations do
  @moduledoc """
  PawChart's Locations domain — the samen_core Locations scope MOUNTED AS-IS
  for the vet vertical (ADR-004; F5, T47), exactly as `PawChart.Docs`/
  `PawChart.Tags` mount their scopes.

  One `use Samen.Scopes.Locations` expands into one host-owned resource:

    * `PawChart.Locations.Location` — for a vet clinic SaaS this is a clinic
      site/branch record. 🔒 vaulted `address` (`vault: :pii_address`,
      ADR-036 H4/c17 composite), no geometry column (ADR-037 §5.10).
      Archivable (ADR-040 §5.9).

  ## Why this mounts cleanly (the additive proof)

  Zero vertical reshape — same posture as `PawChart.Docs`/`PawChart.Tags`.

  ## Abbrev allocation

  Fresh `pll` abbrev (allocator-proposed, no cross-host collision). Scope has
  no pre-claimed scope-default.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Locations,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Locations,
    abbrev: "pll"
end
