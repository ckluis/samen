defmodule Demo.Aggregate.Rebuild do
  @moduledoc """
  Materialize the token-blind aggregate-plane projections (T4.2 clause (c)) from the
  tenant-plane Billing / Support rollup tables.

  This is the demo's rollup step for the cross-tenant aggregate plane. It runs
  CROSS-TENANT (no org filter — the aggregate spans all tenants) and writes ONLY
  bounded, non-PII summary columns (tier / status enums + counts + a cents number)
  into the vault-excluded projection tables. It never touches a `pii_` column — the
  source columns it reads (`bsb_status`, `bpl_name`, `bpr_unit_amount_cents`,
  `stk_status`) are all non-PII, and the destination tables have no `pii_` columns
  (the C7 verifier + `mix samen.verify.no_pii_columns` enforce this).

  In production this would be an AshOban rollup worker (like
  `Samen.Jobs.RollupRefreshWorker`); here it is a plain function the operator
  dashboard test / demo drives.
  """

  @doc """
  Rebuild both aggregate projections (`amr_mrr_by_tier`, `atq_ticket_queue_depth`)
  from the tenant-plane tables. Truncate + recompute in one transaction. Returns
  `{:ok, %{mrr_rows: n, queue_rows: m}}`.
  """
  @spec run(module()) :: {:ok, %{mrr_rows: non_neg_integer(), queue_rows: non_neg_integer()}}
  def run(repo \\ Demo.Repo) do
    {:ok, result} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM amr_mrr_by_tier", [])
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM atq_ticket_queue_depth", [])

        # Cross-tenant MRR by tier: for each plan tier (bpl_name), count distinct
        # orgs on an ACTIVE subscription to a plan of that tier, and sum the plan's
        # monthly price cents. NO org filter — this spans every tenant.
        %{num_rows: mrr_rows} =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO amr_mrr_by_tier (amr_tier, amr_tenant_count, amr_mrr_cents, amr_refreshed_at)
            SELECT
              p.bpl_name                                         AS amr_tier,
              COUNT(DISTINCT s.bsb_org_id)::int                  AS amr_tenant_count,
              COALESCE(SUM(pr.bpr_unit_amount_cents), 0)::int    AS amr_mrr_cents,
              now()                                              AS amr_refreshed_at
            FROM bsb_subscription s
            JOIN bpl_plan p ON p.bpl_id = s.bsb_plan_id
            LEFT JOIN bpr_price pr ON pr.bpr_plan_id = p.bpl_id AND pr.bpr_active = TRUE
            WHERE s.bsb_status = 'active'
            GROUP BY p.bpl_name
            """,
            []
          )

        # Cross-tenant support-queue depth by status. NO org filter.
        %{num_rows: queue_rows} =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO atq_ticket_queue_depth (atq_status, atq_depth, atq_refreshed_at)
            SELECT
              t.stk_status        AS atq_status,
              COUNT(*)::int       AS atq_depth,
              now()               AS atq_refreshed_at
            FROM stk_ticket t
            GROUP BY t.stk_status
            """,
            []
          )

        %{mrr_rows: mrr_rows, queue_rows: queue_rows}
      end)

    {:ok, result}
  end
end
