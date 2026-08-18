defmodule Driftwood.BrokerRollup do
  @moduledoc """
  Refresh the TENANT-plane, per-org **broker summary rollup** (`dbs_broker_summary`,
  T5.3 clause (a)). The broker dashboard reads this small summary — load counts by
  status + settlement totals — instead of scanning raw `fop_opportunity` /
  `stl_settlement` rows into the view (the doc's rollup idiom on the tenant plane).

  This is ORG-SCOPED: `run/2` recomputes the summary for ONE org and writes rows keyed
  `(dbs_org_id, dbs_status)`. It reads only bounded, non-PII columns (load status +
  value cents, settlement net-payable cents) and writes only counts + cents — never a
  `pii_` column. In production this would be an AshOban rollup worker on the T2.1 cron;
  here it is a plain function the broker dashboard / dogfood drives, mirroring
  `Driftwood.Aggregate.Rebuild`.

  The settlement `net_payable_cents` is the `Driftwood.Context` reshape math
  (linehaul − advances − factoring_fee − claims, clamped at 0). The rollup reproduces
  it in SQL exactly (the same truncated factoring-fee arithmetic, OR-5) so the
  dashboard total matches the per-settlement reshape to the cent.
  """

  @doc """
  Recompute `dbs_broker_summary` for `org_id`. Deletes this org's rows and reinserts a
  per-status load rollup + a single settlement-total row (status `__settlements__`).
  Returns `{:ok, %{status_rows: n}}`.
  """
  @spec run(binary(), module()) :: {:ok, %{status_rows: non_neg_integer()}}
  def run(org_id, repo \\ Driftwood.Repo) do
    org_bin = Ecto.UUID.dump!(to_string(org_id))

    {:ok, result} =
      repo.transaction(fn ->
        Ecto.Adapters.SQL.query!(
          repo,
          "DELETE FROM dbs_broker_summary WHERE dbs_org_id = $1",
          [org_bin]
        )

        # Per-status LOAD rollup for this org (counts + gross value cents).
        #
        # ADR-036 §4.5(2): fop_value_cents was dropped by the H1 Money migration;
        # fop_value is now the money_with_currency composite — sum its minor units
        # directly ((composite).amount * 100).
        %{num_rows: status_rows} =
          Ecto.Adapters.SQL.query!(
            repo,
            """
            INSERT INTO dbs_broker_summary
              (dbs_org_id, dbs_status, dbs_load_count, dbs_gross_cents,
               dbs_settlement_count, dbs_net_payable_cents, dbs_refreshed_at)
            SELECT
              l.fop_org_id                               AS dbs_org_id,
              l.fop_status                               AS dbs_status,
              COUNT(*)::int                              AS dbs_load_count,
              COALESCE(SUM((l.fop_value).amount * 100),0)::int AS dbs_gross_cents,
              0                                          AS dbs_settlement_count,
              0                                          AS dbs_net_payable_cents,
              now()                                      AS dbs_refreshed_at
            FROM fop_opportunity l
            WHERE l.fop_org_id = $1
            GROUP BY l.fop_org_id, l.fop_status
            """,
            [org_bin]
          )

        # Single SETTLEMENT-total row for this org. net_payable = max(gross - advances
        # - trunc(gross*bps/10000) - claims, 0), gross = linehaul + fuel + accessorial
        # — the Driftwood.Context reshape, reproduced exactly (OR-5 truncation).
        Ecto.Adapters.SQL.query!(
          repo,
          """
          INSERT INTO dbs_broker_summary
            (dbs_org_id, dbs_status, dbs_load_count, dbs_gross_cents,
             dbs_settlement_count, dbs_net_payable_cents, dbs_refreshed_at)
          SELECT
            $1::uuid AS dbs_org_id,
            '__settlements__' AS dbs_status,
            0 AS dbs_load_count,
            COALESCE(SUM(s.stl_linehaul_cents + s.stl_fuel_surcharge_cents + s.stl_accessorial_cents),0)::int AS dbs_gross_cents,
            COUNT(*)::int AS dbs_settlement_count,
            COALESCE(SUM(GREATEST(
              (s.stl_linehaul_cents + s.stl_fuel_surcharge_cents + s.stl_accessorial_cents)
              - s.stl_advances_cents
              - ( ((s.stl_linehaul_cents + s.stl_fuel_surcharge_cents + s.stl_accessorial_cents) * s.stl_factoring_rate_bps)
                  - ((s.stl_linehaul_cents + s.stl_fuel_surcharge_cents + s.stl_accessorial_cents) * s.stl_factoring_rate_bps) % 10000
                ) / 10000
              - s.stl_claim_deduction_cents,
              0)),0)::int AS dbs_net_payable_cents,
            now() AS dbs_refreshed_at
          FROM stl_settlement s
          WHERE s.stl_org_id = $1
          """,
          [org_bin]
        )

        %{status_rows: status_rows}
      end)

    {:ok, result}
  end

  @doc """
  Read this org's rollup rows straight from `dbs_broker_summary` (never scans the raw
  load/settlement tables). Returns a map with `by_status` (load rollup rows) and
  `settlements` (the settlement-total row or nil).
  """
  @spec summary(binary(), module()) :: %{by_status: [map()], settlements: map() | nil}
  def summary(org_id, repo \\ Driftwood.Repo) do
    org_bin = Ecto.UUID.dump!(to_string(org_id))

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        """
        SELECT dbs_status, dbs_load_count, dbs_gross_cents, dbs_settlement_count, dbs_net_payable_cents
        FROM dbs_broker_summary
        WHERE dbs_org_id = $1
        ORDER BY dbs_status
        """,
        [org_bin]
      )

    parsed =
      Enum.map(rows, fn [status, load_count, gross_cents, settlement_count, net_payable_cents] ->
        %{
          status: status,
          load_count: load_count,
          gross_cents: gross_cents,
          settlement_count: settlement_count,
          net_payable_cents: net_payable_cents
        }
      end)

    {settlements, by_status} = Enum.split_with(parsed, &(&1.status == "__settlements__"))

    %{by_status: by_status, settlements: List.first(settlements)}
  end
end
