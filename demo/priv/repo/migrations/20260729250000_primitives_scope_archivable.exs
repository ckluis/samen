defmodule Demo.Repo.Migrations.PrimitivesScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37e) — the Primitives scope's adoption sub-item: `file`, `webhook`,
  `feature_flag` flip `archivable true`
  (samen_core/lib/samen/scopes/primitives/blueprint.ex). `approval` is explicitly NOT
  archivable per the roster (its own decision-record state machine, T34) and is a
  separate blueprint (`Samen.Approvals.Blueprint`) — untouched. `notification` (L —
  ledger), `notification_preference` (settings row), and `search_index` (M — derived)
  stay excluded — no columns added for any of them.

  The T36 substrate (ash_archival, ADR-037 §5.3 ADOPT) injects one abbrev-prefixed
  `<abbrev>_archived_at :utc_datetime_usec` column per adopting resource (NULL = live).
  §5.3: no `unique_index` exists on `pfl_file` / `pwh_webhook` / `pff_feature_flag`
  today (confirmed by inspecting `20260706060000_add_primitives_scope` — zero
  `unique_index` calls in that migration), so there is nothing to convert to partial
  form — same finding as T37a/b/c/d's scopes.

  Additive columns on already-catalogued resources → `catalog_sync/2`'s `only:`
  scoping, so `down` removes exactly these three `fld_field` rows.
  """
  use Samen.Migration

  def change do
    alter table(:pfl_file) do
      add(:pfl_archived_at, :utc_datetime_usec)
    end

    alter table(:pwh_webhook) do
      add(:pwh_archived_at, :utc_datetime_usec)
    end

    alter table(:pff_feature_flag) do
      add(:pff_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Demo.PrimitivesScope.File], only: [:archived_at])
    catalog_sync([Demo.PrimitivesScope.Webhook], only: [:archived_at])
    catalog_sync([Demo.PrimitivesScope.FeatureFlag], only: [:archived_at])
  end
end
