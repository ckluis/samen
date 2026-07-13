defmodule Demo.Repo.Migrations.AddFeatureFlagEngineFields do
  @moduledoc """
  WS-B B5 — feature-flag evaluation engine (ADR-020; design G6 §3).

  Adds the two engine fields to `pff_feature_flag`:

    * `pff_target_rules` — bounded jsonb array of targeting rules (non-PII keys only,
      refused at write by `Samen.FeatureFlags.NonPiiTargeting`).
    * `pff_variants` — bounded jsonb map (variant name → weight) for the experiment
      seam.
  """
  use Ecto.Migration

  def up do
    alter table(:pff_feature_flag) do
      add(:pff_target_rules, :map, default: fragment("'[]'::jsonb"))
      add(:pff_variants, :map, default: fragment("'{}'::jsonb"))
    end
  end

  def down do
    alter table(:pff_feature_flag) do
      remove(:pff_target_rules)
      remove(:pff_variants)
    end
  end
end
