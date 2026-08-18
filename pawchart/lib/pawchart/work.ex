defmodule PawChart.Work do
  @moduledoc """
  PawChart's Work domain — the samen_core Work scope MOUNTED AS-IS for the vet
  vertical (ADR-004; F1, ADR-041 §3 — the canonical Work-scope Task, T43).

  One `use Samen.Scopes.Work` expands into two host-owned resources in
  `PawChart.Work.*`:

    * `PawChart.Work.Project` — a container noun (name/status/owner). No PII.
    * `PawChart.Work.Task`    — the canonical Task (ADR-041 §3.2). For a vet
      clinic SaaS this is an internal follow-up/reminder task (e.g. "call back
      about vaccine lot recall"), optionally anchored to a CRM object via the
      generic `(subject_key, subject_id)` ref. No PII. This mount touches NO
      CRM code.

  ## Why this mounts cleanly (the additive proof)

  Zero vertical reshape — same posture as `PawChart.Support`.

  ## Abbrev allocation

  Fresh `pw*` abbrevs (`pwp`/`pwt`, allocator-proposed). Scope-default abbrevs
  (`wpj`/`wtk`) are owned by the demo mount; Driftwood owns `dwp`/`dwt`.
  Append-only registry update.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Work,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Work,
    abbrevs: %{
      project: "pwp",
      task: "pwt"
    }
end
