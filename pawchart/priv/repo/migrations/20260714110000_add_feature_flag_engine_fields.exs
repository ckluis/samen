defmodule PawChart.Repo.Migrations.AddFeatureFlagEngineFields do
  @moduledoc """
  WS-B B9 (AC-X1) — the B5 feature-flag evaluation-engine fields (ADR-020) on
  PawChart's Primitives mount: the Primitives blueprint gained `target_rules` +
  `variants` in Phase B5, so every mounted `FeatureFlag` resource (here `vff`)
  needs the physical columns. Mirrors demo's `AddFeatureFlagEngineFields`.

    * `vff_target_rules` — bounded jsonb array of targeting rules (non-PII keys
      only, refused at write by `Samen.FeatureFlags.NonPiiTargeting`).
    * `vff_variants` — bounded jsonb map (variant name → weight) for the
      experiment seam.
  """
  use Ecto.Migration

  def up do
    alter table(:vff_feature_flag) do
      add(:vff_target_rules, :map, default: fragment("'[]'::jsonb"))
      add(:vff_variants, :map, default: fragment("'{}'::jsonb"))
    end
  end

  def down do
    alter table(:vff_feature_flag) do
      remove(:vff_target_rules)
      remove(:vff_variants)
    end
  end
end
