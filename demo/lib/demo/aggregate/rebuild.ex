defmodule Demo.Aggregate.Rebuild do
  @moduledoc """
  Materialize the token-blind aggregate-plane projections (T4.2 clause (c)) from the
  tenant-plane Billing / Support rollup tables.

  This is the demo's rollup step for the cross-tenant aggregate plane. It runs
  CROSS-TENANT (no org filter — the aggregate spans all tenants) and writes ONLY
  bounded, non-PII summary columns (tier / status / band enums + counts + a cents
  number) into the vault-excluded projection tables. It never touches a `pii_`
  column — the source columns it reads (`bsb_status`, `bpl_name`,
  `bpr_unit_amount` (ADR-036 H1: the money_with_currency composite, formerly
  `bpr_unit_amount_cents`), `stk_status`, `bin_status`, `bin_due_date`) are all
  non-PII, and the destination tables have no `pii_` columns (the C7 verifier + `mix
  samen.verify.no_pii_columns` enforce this).

  In production this would be an AshOban rollup worker (like
  `Samen.Jobs.RollupRefreshWorker`); here it is a plain function the operator
  dashboard test / demo drives.

  ## Health-band derivation (AC-G17-6)

  `ahb_health_by_band` counts accounts per health BAND across the fleet. The band is
  derived cross-tenant in SQL from the SAME dunning-dominant billing signal the
  tenant-plane `Samen.Web.Operator.HealthScore` uses (a subject-free, bounded
  projection — the score module itself lives in `samen_web`, which the demo does not
  depend on; the cross-tenant aggregate needs only the band LABEL + a count, not the
  full breakdown). The band buckets, worst-wins:

    * `at_risk` — the account is IN DUNNING: an active subscription with a `:past_due`
      / `:unpaid` status, OR any past-due (`:open` + overdue) invoice on the books.
      This is the "how many accounts are at-risk across the fleet" case the design
      names, and the AC-G17-6 red-path probes.
    * `critical` — a `:cancelled` / `:inactive` subscription, or no subscription at all.
    * `healthy` — an `:active` / `:trialing` subscription with no past-due signal.

  Each tenant org counts ONCE (its worst band). The count per band is the cohort SIZE
  the k-anon floor compares to `k` — a band with `< k` accounts across the fleet
  renders `%Suppressed{}` (the operator can never learn "there is exactly 1 critical
  account").
  """

  @doc """
  Rebuild the three aggregate projections (`amr_mrr_by_tier`,
  `atq_ticket_queue_depth`, `ahb_health_by_band`) from the tenant-plane tables.
  Truncate + recompute in one transaction. Returns
  `{:ok, %{mrr_rows: n, queue_rows: m, band_rows: b}}`.
  """
  @spec run(module()) ::
          {:ok,
           %{
             mrr_rows: non_neg_integer(),
             queue_rows: non_neg_integer(),
             band_rows: non_neg_integer()
           }}
  def run(repo \\ Demo.Repo) do
    {:ok, result} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM amr_mrr_by_tier", [])
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM atq_ticket_queue_depth", [])
        Ecto.Adapters.SQL.query!(repo, "DELETE FROM ahb_health_by_band", [])

        # Cross-tenant MRR by tier: for each plan tier (bpl_name), count distinct
        # orgs on an ACTIVE subscription to a plan of that tier, and sum the plan's
        # monthly price cents. NO org filter — this spans every tenant.
        #
        # ADR-036 §4.5(2): bpr_unit_amount_cents was dropped by the H1 Money
        # migration; bpr_unit_amount is now the money_with_currency composite —
        # sum its minor units directly ((composite).amount * 100), never re-widen
        # to a paired column.
        %{num_rows: mrr_rows} =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO amr_mrr_by_tier (amr_tier, amr_tenant_count, amr_mrr_cents, amr_refreshed_at)
            SELECT
              p.bpl_name                                                AS amr_tier,
              COUNT(DISTINCT s.bsb_org_id)::int                         AS amr_tenant_count,
              COALESCE(SUM((pr.bpr_unit_amount).amount * 100), 0)::int  AS amr_mrr_cents,
              now()                                                     AS amr_refreshed_at
            FROM bsb_subscription s
            JOIN bpl_plan p ON p.bpl_id = s.bsb_plan_id
            LEFT JOIN bpr_price pr ON pr.bpr_plan_id = p.bpl_id AND pr.bpr_active = TRUE
            WHERE s.bsb_status = 'active'
            GROUP BY p.bpl_name
            """,
            []
          )

        # Cross-tenant support-queue depth by status. NO org filter. Also compute the
        # l-diversity distinct-sensitive count: how many DISTINCT ticket PRIORITIES ride
        # this status cohort (the sensitive dimension the demo proves — T4.5 clause (b)).
        %{num_rows: queue_rows} =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO atq_ticket_queue_depth
              (atq_status, atq_depth, atq_distinct_priorities, atq_refreshed_at)
            SELECT
              t.stk_status                        AS atq_status,
              COUNT(*)::int                       AS atq_depth,
              COUNT(DISTINCT t.stk_priority)::int AS atq_distinct_priorities,
              now()                               AS atq_refreshed_at
            FROM stk_ticket t
            GROUP BY t.stk_status
            """,
            []
          )

        # Cross-tenant health-band distribution (AC-G17-6). Bucket every tenant org
        # into its worst health band from the dunning-dominant billing signal, then
        # count orgs per band. NO org filter — spans the whole fleet. Each org counts
        # ONCE (its worst band, via the per-org band CTE). The count per band is the
        # cohort size the k-anon floor suppresses when < k.
        %{num_rows: band_rows} =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO ahb_health_by_band (ahb_band, ahb_account_count, ahb_refreshed_at)
            WITH org_dunning AS (
              -- an org is IN DUNNING if it has a past_due/unpaid subscription OR a
              -- past-due (:open + overdue) invoice.
              SELECT DISTINCT o.ido_id AS org_id
              FROM ido_org o
              WHERE EXISTS (
                      SELECT 1 FROM bsb_subscription s
                      WHERE s.bsb_org_id = o.ido_id
                        AND s.bsb_status IN ('past_due', 'unpaid')
                    )
                 OR EXISTS (
                      SELECT 1 FROM bin_invoice i
                      WHERE i.bin_org_id = o.ido_id
                        AND i.bin_status = 'open'
                        AND i.bin_due_date IS NOT NULL
                        AND i.bin_due_date < now()
                    )
            ),
            org_active AS (
              -- an org has a LIVE subscription (active/trialing) if it has one that is
              -- not cancelled/inactive.
              SELECT DISTINCT s.bsb_org_id AS org_id
              FROM bsb_subscription s
              WHERE s.bsb_status IN ('active', 'trialing')
            ),
            org_band AS (
              SELECT
                o.ido_id AS org_id,
                CASE
                  WHEN d.org_id IS NOT NULL THEN 'at_risk'
                  WHEN a.org_id IS NOT NULL THEN 'healthy'
                  ELSE 'critical'
                END AS band
              FROM ido_org o
              LEFT JOIN org_dunning d ON d.org_id = o.ido_id
              LEFT JOIN org_active  a ON a.org_id = o.ido_id
            )
            SELECT
              band            AS ahb_band,
              COUNT(*)::int   AS ahb_account_count,
              now()           AS ahb_refreshed_at
            FROM org_band
            GROUP BY band
            """,
            []
          )

        %{mrr_rows: mrr_rows, queue_rows: queue_rows, band_rows: band_rows}
      end)

    {:ok, result}
  end
end
