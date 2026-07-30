defmodule Driftwood.Work do
  @moduledoc """
  Driftwood's Work domain — mounted from the samen_core Work scope blueprint
  (ADR-004; F1, ADR-041 §3 — the canonical Work-scope Task, T43), exactly as
  `Driftwood.Support` mounts the Support scope.

  One `use Samen.Scopes.Work` expands into two host-owned resources in
  `Driftwood.Work.*`:

    * `Driftwood.Work.Project` — a container noun (name/status/owner). No PII.
    * `Driftwood.Work.Task`    — the canonical Task (ADR-041 §3.2). No PII. Carries
      the generic `(subject_key, subject_id)` object-ref anchor — CRM-agnostic by
      construction (ADR-041 §4.1). This mount touches NO CRM code.

  ## Abbrev allocation (fresh abbrevs)

  The Work scope-DEFAULT abbrevs (`wpj`/`wtk`) are already owned by the demo mount.
  Driftwood takes FRESH abbrevs (`dwp`/`dwt`, allocator-proposed) via the blueprint's
  `abbrevs:` override — the same collision-avoidance shape `Driftwood.Support` uses
  for its `fsk/fsc/…` abbrevs.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Work,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Work,
    abbrevs: %{
      project: "dwp",
      task: "dwt"
    }
end
