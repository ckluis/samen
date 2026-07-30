defmodule PawChart.Calendar do
  @moduledoc """
  PawChart's Calendar domain — the samen_core Calendar scope MOUNTED AS-IS
  for the vet vertical (ADR-004; F2, T44), exactly as `PawChart.Work` mounts
  the Work scope.

  One `use Samen.Scopes.Calendar` expands into one host-owned resource:

    * `PawChart.Calendar.Event` — for a vet clinic SaaS this is an
      appointment/checkup (`kind: :meeting`) or a clinic event; 🔒 vaulted
      `attendees` (owner + any co-attendee emails), `location`, an optional
      `recurrence` rule (e.g. a recurring wellness-check reminder series).
      Archivable (ADR-040 §5.9).

  ## Why this mounts cleanly (the additive proof)

  Zero vertical reshape — same posture as `PawChart.Work`.

  ## Abbrev allocation

  Fresh `pce` abbrev (allocator-proposed). Scope has no pre-claimed
  scope-default (unlike Work's demo-owned `wpj`/`wtk`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Calendar,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Calendar,
    abbrevs: %{event: "pce"}
end
