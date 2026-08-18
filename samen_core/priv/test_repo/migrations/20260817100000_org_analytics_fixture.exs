defmodule SamenCore.TestRepo.Migrations.OrgAnalyticsFixture do
  @moduledoc """
  P17 (ADR-045 §3): the `oea_org_metric` table backing the org-scoped aggregate fixture
  `SamenCore.Support.OrgAnalyticsFixture.Metric` — the DB-backed projection the
  `Samen.Aggregate.read_all_for_org/3` tests read (org-partitioned floors + cross-org
  isolation). A vault-excluded projection: every column is a bounded id (uuid), a bounded
  enum label (kind), or a count (subject_count / metric) — no plaintext PII type.

  Plain `Ecto.Migration` (no `catalog_sync`) — the fixture is NOT registered in any
  `:ash_domains`, so no whole-app catalog/verifier scans it; the read path itself needs
  no catalog row. `oea_org_id` is NOT NULL (the real org partition the org-scoped arm
  requires).
  """
  use Ecto.Migration

  def up do
    execute(
      """
      CREATE TABLE oea_org_metric (
        oea_id            UUID        NOT NULL DEFAULT gen_random_uuid(),
        oea_org_id        UUID        NOT NULL,
        oea_kind          TEXT        NOT NULL,
        oea_subject_count INTEGER     NOT NULL DEFAULT 0,
        oea_metric        INTEGER     NOT NULL DEFAULT 0,
        oea_inserted_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
        oea_updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (oea_id)
      )
      """,
      "DROP TABLE IF EXISTS oea_org_metric"
    )

    execute(
      "CREATE INDEX oea_org_metric_org_idx ON oea_org_metric (oea_org_id, oea_kind)",
      "DROP INDEX IF EXISTS oea_org_metric_org_idx"
    )
  end

  def down do
    execute("DROP INDEX IF EXISTS oea_org_metric_org_idx")
    execute("DROP TABLE IF EXISTS oea_org_metric")
  end
end
