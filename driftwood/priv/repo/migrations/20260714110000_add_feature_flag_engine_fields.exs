defmodule Driftwood.Repo.Migrations.AddFeatureFlagEngineFields do
  @moduledoc """
  WS-B B9 (AC-X1) — the B5 feature-flag evaluation-engine fields (ADR-020) on
  Driftwood's Primitives mount: the Primitives blueprint gained `target_rules` +
  `variants` in Phase B5, so every mounted `FeatureFlag` resource (here `fff`)
  needs the physical columns. Mirrors demo's `AddFeatureFlagEngineFields`.

    * `fff_target_rules` — bounded jsonb array of targeting rules (non-PII keys
      only, refused at write by `Samen.FeatureFlags.NonPiiTargeting`).
    * `fff_variants` — bounded jsonb map (variant name → weight) for the
      experiment seam.
  """
  use Ecto.Migration

  def up do
    alter table(:fff_feature_flag) do
      add(:fff_target_rules, :map, default: fragment("'[]'::jsonb"))
      add(:fff_variants, :map, default: fragment("'{}'::jsonb"))
    end
  end

  def down do
    alter table(:fff_feature_flag) do
      remove(:fff_target_rules)
      remove(:fff_variants)
    end
  end
end
