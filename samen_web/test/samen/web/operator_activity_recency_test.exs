defmodule Samen.Web.OperatorActivityRecencyTest do
  @moduledoc """
  G17b — the `pae` (`Analytics.ProductEvent`, ADR-021) RECENCY signal wired into the
  operator health score's `:activity` factor (ADR-019, AC-G17-7). `Samen.Web.Operator.Reads`
  assembles `__activity_days__` from each account's most-recent `pae` event; the pure
  `HealthScore` then bands it (≤7d → 1.0, ≤90d → 0.35, else 0.1; absent → `:unknown`).

  This is the FIDELITY wire-up's DB-backed proof — the pure banding is covered by
  `Samen.Web.OperatorHealthScoreTest`. Here the seam is exercised end-to-end against the
  standalone operator book + the samen_web test-host `pae` ledger
  (`Samen.WebTest.Analytics.ProductEvent`, `wan`), wired as the framework product-event
  target exactly as a real host does once in config:

    * POSITIVE control — an account with a FRESH `pae` event yields an INTEGER
      `__activity_days__` and a KNOWN (non-`:unknown`), HEALTHY (value 1.0) activity factor;
    * an account with an OLD `pae` event yields a larger integer day count and the DORMANT
      band (value 0.1);
    * NEGATIVE control — an account with NO `pae` event (in the SAME assembly) yields
      `__activity_days__ == nil` → the `:unknown` activity factor (graceful fallback,
      renormalizing weights) — anti-tautology, positive AND negative in one read;
    * the CONFIG SEAM is load-bearing — with the product-event resource UNWIRED, the very
      same seeded `pae` rows are invisible and EVERY account degrades to `:unknown` (the
      pre-G17b behaviour the existing operator/health tests rely on);
    * the renormalization invariant holds — the breakdown still SUMS to the composite with
      the now-known factor;
    * NO PII — `__activity_days__` is a bounded non-negative INTEGER (the `pae` read touches
      only a timestamp; `pae` carries no subject identity column).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator.HealthScore
  alias Samen.Web.Operator.Reads
  alias Samen.WebTest.Analytics.ProductEvent
  alias Samen.WebTest.Operator.Seeds, as: OpSeeds

  setup do
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    wire_product_events(ProductEvent)
    on_exit(fn -> Application.delete_env(:samen_core, Samen.Analytics) end)

    # Three accounts: 1 = FRESH activity, 2 = OLD activity, 3 = NO activity.
    seed = OpSeeds.seed_all(tenants: 3)
    [fresh, old, none] = Enum.map(seed.accounts, & &1.tenant_org_id)
    %{seed: seed, fresh: fresh, old: old, none: none}
  end

  # Wire (or unwire, on nil) the framework product-event target — the same seam
  # `Samen.Analytics.track/1` + `AnalyticsReads` use to reach `pae` across scopes.
  defp wire_product_events(nil), do: Application.delete_env(:samen_core, Samen.Analytics)
  defp wire_product_events(mod), do: Application.put_env(:samen_core, Samen.Analytics, product_event_resource: mod)

  # Append one token-blind `pae` row for a tenant org at a given age (whole days ago).
  defp seed_event(tenant_org_id, days_ago) do
    occurred_at =
      DateTime.utc_now()
      |> DateTime.add(-days_ago * 86_400, :second)
      |> DateTime.truncate(:second)

    ProductEvent
    |> Ash.Changeset.for_create(
      :append,
      %{
        org_id: tenant_org_id,
        event_name: :"record.created",
        event_kind: :record,
        occurred_at: occurred_at
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp rows(seed) do
    mount = build_operator_mount(seed.operator_org_id)
    scope = Samen.Web.Operator.scope(mount)
    Reads.accounts(mount, scope, seed.operator_org_id)
  end

  defp row_for(rows, tenant_org_id), do: Enum.find(rows, &(&1.tenant_org_id == tenant_org_id))
  defp activity(row), do: Enum.find(row.__health__.factors, &(&1.name == :activity))

  # ---------------------------------------------------------------------------

  test "GREEN: a FRESH pae event → integer __activity_days__ and a KNOWN, healthy (1.0) activity factor",
       %{seed: seed, fresh: fresh} do
    seed_event(fresh, 0)

    row = row_for(rows(seed), fresh)
    a = activity(row)

    # The reads layer computed a real non-negative INTEGER day count (not nil).
    assert is_integer(row.__activity_days__)
    assert row.__activity_days__ >= 0
    assert row.__activity_days__ <= 7

    # KNOWN activity factor, top band — no longer excluded.
    refute a.value == :unknown
    assert a.value == 1.0
    assert HealthScore.factor_band(a) == :healthy
    assert a.contribution > 0.0
    assert a.explanation =~ "product activity in the last 7 days"
  end

  test "an OLD pae event → a larger integer day count and the DORMANT band (0.1)",
       %{seed: seed, old: old} do
    seed_event(old, 200)

    row = row_for(rows(seed), old)
    a = activity(row)

    assert is_integer(row.__activity_days__)
    assert row.__activity_days__ >= 90
    assert a.value == 0.1
    assert HealthScore.factor_band(a) != :healthy
    assert HealthScore.factor_band(a) != :unknown
    assert a.explanation =~ "dormant"
  end

  test "NEGATIVE control (same assembly): an account with NO pae event → nil → the :unknown activity factor",
       %{seed: seed, fresh: fresh, none: none} do
    seed_event(fresh, 0)
    # `none` gets no event — in the SAME read where `fresh` is KNOWN.

    all = rows(seed)
    fresh_row = row_for(all, fresh)
    none_row = row_for(all, none)

    # Positive AND negative in one assembly (anti-tautology).
    assert is_integer(fresh_row.__activity_days__)
    refute activity(fresh_row).value == :unknown

    assert is_nil(none_row.__activity_days__)
    assert activity(none_row).value == :unknown
    assert activity(none_row).contribution == 0.0
    assert activity(none_row).explanation =~ "G12"
  end

  test "the CONFIG SEAM is load-bearing: with the product-event resource UNWIRED, the SAME seeded rows are invisible and every account degrades to :unknown",
       %{seed: seed, fresh: fresh, old: old} do
    # Seed real pae rows...
    seed_event(fresh, 0)
    seed_event(old, 200)

    # ...but UNWIRE the framework target (the samen_web default; the existing
    # operator/health tests run in exactly this state and expect :unknown).
    wire_product_events(nil)

    all = rows(seed)

    for tid <- [fresh, old] do
      row = row_for(all, tid)
      assert is_nil(row.__activity_days__), "unwired target must not read pae rows"
      assert activity(row).value == :unknown
    end
  end

  test "the renormalization invariant holds with the now-known factor: the breakdown SUMS to the composite",
       %{seed: seed, fresh: fresh} do
    seed_event(fresh, 0)

    row = row_for(rows(seed), fresh)
    b = row.__health__

    # AC-G17-1: the composite IS the rounded sum of the per-factor contributions —
    # the known activity factor is folded in, not double-counted or dropped.
    assert b.score == round(Enum.reduce(b.factors, 0.0, &(&1.contribution + &2)))
    assert b.score in 0..100
    # Activity is now a KNOWN factor contributing real points.
    assert activity(row).value == 1.0
    assert activity(row).contribution > 0.0
  end

  test "NO PII: __activity_days__ is a bounded non-negative integer, never a name/email/token",
       %{seed: seed, fresh: fresh, old: old} do
    seed_event(fresh, 3)
    seed_event(old, 45)

    all = rows(seed)

    for tid <- [fresh, old] do
      days = row_for(all, tid).__activity_days__
      assert is_integer(days) and days >= 0
      # A bounded integer is not a PII carrier — no vault token, no string payload.
      refute is_binary(days)
    end
  end
end
