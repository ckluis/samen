defmodule SamenCore.TestRepo.Migrations.FeatureFlagEngineFields do
  @moduledoc """
  WS-B B5 UNIT 1 — the feature-flag evaluation engine (ADR-020; design G6 §3).

  Adds the two engine fields to the `ngf_feature_flag` fixture table so the
  `Samen.FeatureFlags` engine + cache can be exercised against a real Postgres DB in
  `samen_core` (via `test/support/notification_fixture.ex`, which mounts the
  Primitives scope under the `ne*` / `ngf` abbrev set):

    * `ngf_target_rules` — bounded jsonb array of targeting rules (non-PII keys only,
      enforced at write by `Samen.FeatureFlags.NonPiiTargeting`).
    * `ngf_variants` — bounded jsonb map (variant name → weight) for the multivariate
      experiment seam.
  """
  use Ecto.Migration

  def up do
    alter table(:ngf_feature_flag) do
      add(:ngf_target_rules, :map, default: fragment("'[]'::jsonb"))
      add(:ngf_variants, :map, default: fragment("'{}'::jsonb"))
    end
  end

  def down do
    alter table(:ngf_feature_flag) do
      remove(:ngf_target_rules)
      remove(:ngf_variants)
    end
  end
end
