defmodule Driftwood.Locations do
  @moduledoc """
  Driftwood's Locations domain — mounted from the samen_core Locations scope
  blueprint (ADR-004; F5, T47), exactly as `Driftwood.Docs`/`Driftwood.Tags`
  mount their scopes.

  One `use Samen.Scopes.Locations` expands into one host-owned resource:

    * `Driftwood.Locations.Location` — a freight-lane site/office/warehouse
      record. 🔒 vaulted `address` (`vault: :pii_address`, ADR-036 H4/c17
      composite), no geometry column (ADR-037 §5.10). Archivable
      (ADR-040 §5.9).

  ## Abbrev allocation — incident + repair (fresh abbrev, not the collision)

  Locations has no scope-default abbrev — every host takes a fresh
  allocator-proposed abbrev. Driftwood's FIRST proposal collided with demo's
  own proposal (`dll` — both host names start with "d", the same
  "host-name-blind proposer" collision class T44/T45/T46 each documented for
  Calendar/Docs/Tags), but this time the collision was caught only AFTER the
  bad `dll` reservation had already been persisted to the committed registry
  (unlike the prior three tasks, which caught it pre-write). The orphaned
  `hosts.driftwood.dll` row was removed as a sanctioned incident-repair (the
  prime orchestrator, not a hand-allocation — see
  `_orch/tasks/T47/work/progress.md` for the full incident record), and
  Driftwood's Location mount took the corrected, allocator-reserved `fll`
  (same f-prefix collision-avoidance convention as `fdd`/`fce`/`ftt`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Locations,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Locations,
    abbrev: "fll"
end
