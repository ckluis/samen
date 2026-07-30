defmodule PawChart.Docs do
  @moduledoc """
  PawChart's Docs domain — the samen_core Docs scope MOUNTED AS-IS for the vet
  vertical (ADR-004; F3, T45), exactly as `PawChart.Calendar` mounts the
  Calendar scope.

  One `use Samen.Scopes.Docs` expands into two host-owned resources:

    * `PawChart.Docs.Doc` — for a vet clinic SaaS this is a care-plan runbook
      or clinic policy doc; 🔒 vaulted `secure_body` (`vault: :pii_doc_body`)
      for PII-classified content (e.g. a note that quotes an owner's contact
      details), attachable to any Clinical/CRM object via the generic
      object-ref anchor. Archivable (ADR-040 §5.9).
    * `PawChart.Docs.Note` — a short annotation, same posture (`vault:
      :pii_note_body`).

  ## Why this mounts cleanly (the additive proof)

  Zero vertical reshape — same posture as `PawChart.Calendar`.

  ## Abbrev allocation

  Fresh `pdd`/`pdn` abbrevs (allocator-proposed). Scope has no pre-claimed
  scope-default (unlike Work's demo-owned `wpj`/`wtk`).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Docs,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Docs,
    abbrevs: %{doc: "pdd", note: "pdn"}
end
