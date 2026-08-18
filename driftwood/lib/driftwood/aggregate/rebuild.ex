defmodule Driftwood.Aggregate.Rebuild do
  @moduledoc """
  Materialize the token-blind aggregate-plane projections (T5.3 clause (b); T4.2
  clause (c) on the freight shape) from the tenant-plane freight rollup rows.

  This is Driftwood's rollup step for the cross-tenant aggregate plane. It runs
  CROSS-TENANT (no org filter — the aggregate spans all brokerages) and writes ONLY
  bounded, non-PII summary columns (lane / tier enums + counts + cents numbers) into
  the vault-excluded projection tables. It never touches a `pii_` column — the source
  columns it reads (`fop_status`, `fop_value` (ADR-036 H1: the
  money_with_currency composite, formerly `fop_value_cents`), `fop_custom->>'lane'`,
  `fcm_custom->>'plan_tier'`, `fcm_custom->>'mrr_cents'`) are all non-PII, and the
  destination tables have no `pii_` columns (the C7 verifier + `mix
  samen.verify.no_pii_columns` enforce this).

  In production this would be an AshOban rollup worker; here it is a plain function
  the operator dashboard test / dogfood drives — mirroring `Demo.Aggregate.Rebuild`.
  """

  @doc """
  Rebuild both aggregate projections (`dag_load_volume_by_lane`, `dtq_mrr_by_tier`)
  from the tenant-plane tables. Truncate + recompute in one transaction. Returns
  `{:ok, %{lane_rows: n, tier_rows: m}}`.
  """
  @spec run(module()) :: {:ok, %{lane_rows: non_neg_integer(), tier_rows: non_neg_integer()}}
  def run(repo \\ Driftwood.Repo) do
    {:ok, result} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM dag_load_volume_by_lane", [])
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM dtq_mrr_by_tier", [])

        # Cross-tenant LOAD VOLUME by lane: for each lane bucket (fop_custom->>'lane'),
        # count distinct brokerages with a load on that lane, count loads, and sum the
        # load gross value cents. NO org filter — this spans every brokerage tenant.
        #
        # ADR-036 §4.5(2): fop_value_cents was dropped by the H1 Money migration;
        # fop_value is now the money_with_currency composite — sum its minor units
        # directly ((composite).amount * 100).
        %{num_rows: lane_rows} =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO dag_load_volume_by_lane
              (dag_lane, dag_tenant_count, dag_load_count, dag_gross_cents, dag_refreshed_at)
            SELECT
              COALESCE(l.fop_custom->>'lane', 'unknown')        AS dag_lane,
              COUNT(DISTINCT l.fop_org_id)::int                 AS dag_tenant_count,
              COUNT(*)::int                                     AS dag_load_count,
              COALESCE(SUM((l.fop_value).amount * 100), 0)::int AS dag_gross_cents,
              now()                                             AS dag_refreshed_at
            FROM fop_opportunity l
            GROUP BY COALESCE(l.fop_custom->>'lane', 'unknown')
            """,
            []
          )

        # Cross-tenant brokerage MRR by plan tier. A brokerage tenant's plan tier +
        # monthly recurring cents ride the Company (Carrier) custom bag (a Tier-1
        # custom field). Count distinct orgs per tier and sum the mrr cents. NO org
        # filter — this spans every tenant.
        %{num_rows: tier_rows} =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO dtq_mrr_by_tier
              (dtq_tier, dtq_tenant_count, dtq_mrr_cents, dtq_refreshed_at)
            SELECT
              c.fcm_custom->>'plan_tier'                                          AS dtq_tier,
              COUNT(DISTINCT c.fcm_org_id)::int                                   AS dtq_tenant_count,
              COALESCE(SUM((c.fcm_custom->>'mrr_cents')::int), 0)::int            AS dtq_mrr_cents,
              now()                                                              AS dtq_refreshed_at
            FROM fcm_company c
            WHERE c.fcm_custom->>'plan_tier' IS NOT NULL
            GROUP BY c.fcm_custom->>'plan_tier'
            """,
            []
          )

        %{lane_rows: lane_rows, tier_rows: tier_rows}
      end)

    {:ok, result}
  end
end
