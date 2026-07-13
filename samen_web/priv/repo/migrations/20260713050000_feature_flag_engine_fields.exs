defmodule Samen.WebTest.Repo.Migrations.FeatureFlagEngineFields do
  @moduledoc """
  WS-B B6 UNIT 1 — the two-plane flag admin (ADR-020; design G6 §3.5).

  Adds the two B5 engine fields to the `wng_feature_flag` table (the samen_web
  test host's Primitives-scope FeatureFlag, `Samen.WebTest.Primitives.FeatureFlag`)
  so the tenant `Flags.SettingsLive` + operator `FlagAdminLive` surfaces can be
  exercised against a real Postgres DB:

    * `wng_target_rules` — bounded jsonb array of targeting rules (non-PII keys
      only, enforced at write by `Samen.FeatureFlags.NonPiiTargeting` — RP-F3).
    * `wng_variants` — bounded jsonb map (variant name → weight) for the
      multivariate experiment seam.
  """
  use Ecto.Migration

  def up do
    alter table(:wng_feature_flag) do
      add(:wng_target_rules, :map, default: fragment("'[]'::jsonb"))
      add(:wng_variants, :map, default: fragment("'{}'::jsonb"))
    end
  end

  def down do
    alter table(:wng_feature_flag) do
      remove(:wng_target_rules)
      remove(:wng_variants)
    end
  end
end
