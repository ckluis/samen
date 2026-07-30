defmodule Driftwood.Calendar do
  @moduledoc """
  Driftwood's Calendar domain — mounted from the samen_core Calendar scope
  blueprint (ADR-004; F2, T44), exactly as `Driftwood.Work` mounts the Work
  scope.

  One `use Samen.Scopes.Calendar` expands into one host-owned resource:

    * `Driftwood.Calendar.Event` — Event/Meeting (`kind` distinguishes):
      start/end, 🔒 vaulted `attendees` (`vault: :pii_attendees`), `location`,
      an optional `recurrence` rule. Archivable (ADR-040 §5.9).

  ## Abbrev allocation (fresh abbrev)

  The Calendar scope has no scope-default abbrev (unlike Work's demo-claimed
  `wpj`/`wtk`) — every host takes a fresh allocator-proposed abbrev.
  Driftwood's initial proposal (`dce`) collided with demo's own proposal
  (both host names start with "d" — the deterministic proposer is host-
  name-blind to OTHER host sections), so Driftwood took `fce` instead
  (same f-prefixed collision-avoidance convention `Driftwood.Support` uses).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Calendar,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Calendar,
    abbrevs: %{event: "fce"}
end
