defmodule PawChart.Tags do
  @moduledoc """
  PawChart's Tags domain — the samen_core Tags scope MOUNTED AS-IS for the vet
  vertical (ADR-004; F4, T46), exactly as `PawChart.Docs` mounts the Docs scope.

  One `use Samen.Scopes.Tags` expands into two host-owned resources:

    * `PawChart.Tags.Tag` — for a vet clinic SaaS, an org-scoped colored label
      (e.g. "urgent-care", "boarding") attachable to any Clinical/CRM/Support
      object via the generic object-ref anchor. Archivable (ADR-040 §5.9).
    * `PawChart.Tags.Tagging` — the polymorphic join. NOT archivable (a pure join
      row; untag is a real destroy).

  ## Why this mounts cleanly (the additive proof)

  Zero vertical reshape — same posture as `PawChart.Docs`.

  ## Abbrev allocation

  Fresh `ptt`/`tpt` abbrevs (allocator-proposed). Scope has no pre-claimed
  scope-default (unlike Work's demo-owned `wpj`/`wtk`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Tags,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Tags,
    abbrevs: %{tag: "ptt", tagging: "tpt"}
end
