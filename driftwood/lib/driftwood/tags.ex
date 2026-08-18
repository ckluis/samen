defmodule Driftwood.Tags do
  @moduledoc """
  Driftwood's Tags domain — mounted from the samen_core Tags scope blueprint
  (ADR-004; F4, T46), exactly as `Driftwood.Docs` mounts the Docs scope. One
  `use Samen.Scopes.Tags` expands into two host-owned resources:

    * `Driftwood.Tags.Tag`     — an org-scoped, colored label (e.g. "detention",
      "vip-shipper"), attachable to any Freight/CRM/Support object via the generic
      object-ref anchor. Archivable (ADR-040 §5.9).
    * `Driftwood.Tags.Tagging` — the polymorphic join. NOT archivable (a pure join
      row; untag is a real destroy).

  ## Abbrev allocation (a repeat of the T44/T45 host-name-blind-proposer collision)

  The deterministic `--propose` allocator's initial proposal (`dtt`/`tdt`) collided
  with demo's own proposal (both host names start with "d" — the SAME collision
  class `dce`/`fce` (Calendar) and `ddd`/`fdd` (Docs) already hit), so Driftwood
  took explicit `ftt`/`tft` instead (the "f"-for-freight prefix Driftwood already
  uses for `fsk/fsc/…`/`fdd/fdn`). No samen_core CODE changed — only the data-file
  registry gained Driftwood's reserved rows (append-only); the two orphaned,
  never-referenced `dtt`/`tdt` driftwood rows created by the initial (colliding)
  proposal were removed before any code referenced them, same as T45's own
  documented self-correction.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Tags,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Tags,
    abbrevs: %{tag: "ftt", tagging: "tft"}
end
