defmodule Samen.OrgAnalyticsTest do
  @moduledoc """
  P17 (ADR-045 §3) — `Samen.Aggregate.read_all_for_org/3`, the SEPARATE org-scoped
  aggregate path. Proves the three covert-channel disciplines the brief names, over the
  DB-backed org-scoped fixture `SamenCore.Support.OrgAnalyticsFixture.Metric`:

    1. **Sub-floor suppression (fail closed)** — a count-of-one (or `< k`) cohort has its
       releasable value REPLACED by `%Suppressed{}` (⊘); a `>= k` cohort releases. The
       floor is load-bearing (the same anti-tautology discriminator cuts both ways), and
       the read REUSES the shipped `Samen.Aggregate.Privacy.apply/3` — it is NOT
       reimplemented here.
    2. **Cross-org isolation** — reading as org A's actor returns ONLY org A's cohorts;
       org B's rows are INVISIBLE (Samen.Policy.OrgScope FilterCheck). The org path never
       spans orgs.
    3. **Fail-closed guards** — an org-LESS actor is refused BEFORE any row is read
       (`:org_scope_required`); a non-aggregate resource (`:not_aggregate_resource`) and a
       CROSS-tenant aggregate resource (`:not_org_scoped_aggregate`) are refused — the
       org path admits only org-scoped aggregate resources, T144 / the cross-tenant plane
       untouched.

  Plus the org-scoped arm of `mix samen.verify.aggregate_privacy` (a claim of org-scope
  with a NULLABLE org_id — no real partition — FAILS; a real non-null partition passes).
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.Aggregate
  alias Samen.Aggregate.Suppressed
  alias SamenCore.Support.OrgAnalyticsFixture.{CrossTenant, Metric, NoPartition}
  alias Mix.Tasks.Samen.Verify.AggregatePrivacy

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp org_actor(org_id),
    do: %{id: Ash.UUID.generate(), org_id: org_id, role: :member, plane: :tenant}

  # Seed one cohort row for an org via raw SQL (the projection is read-only — rows arrive
  # from a rollup refresh in production; here we plant them directly).
  defp seed(org_id, kind, subject_count, metric) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "INSERT INTO oea_org_metric (oea_org_id, oea_kind, oea_subject_count, oea_metric) VALUES ($1, $2, $3, $4)",
      [Ecto.UUID.dump!(org_id), kind, subject_count, metric]
    )
  end

  defp fetch(rows, kind), do: Enum.find(rows, &(&1.kind == kind))

  # ---------------------------------------------------------------------------
  # (1) Sub-floor suppression — the shipped floor, load-bearing
  # ---------------------------------------------------------------------------

  test "k-anon: a count-of-one cohort SUPPRESSES its value (⊘); a >= k cohort RELEASES" do
    org = Ash.UUID.generate()
    seed(org, "big", 7, 4200)
    seed(org, "lonely", 1, 999)

    assert {:ok, rows} = Aggregate.read_all_for_org(Metric, org_actor(org), k: 5, l: 2)

    assert %{metric: 4200} = fetch(rows, "big")
    lonely = fetch(rows, "lonely")
    assert Suppressed.suppressed?(lonely.metric)
    assert lonely.metric.reason == :k_anonymity
    # the withheld value 999 is structurally absent — it cannot serialize out
    refute to_string(lonely.metric) =~ "999"
    assert to_string(lonely.metric) == Suppressed.glyph()
  end

  test "anti-tautology: the SAME cohort both suppresses (k=8) AND releases (k=5) — not always-suppress" do
    org = Ash.UUID.generate()
    seed(org, "mid", 6, 1234)

    assert {:ok, [supp]} = Aggregate.read_all_for_org(Metric, org_actor(org), k: 8)
    assert Suppressed.suppressed?(supp.metric)

    assert {:ok, [rel]} = Aggregate.read_all_for_org(Metric, org_actor(org), k: 5)
    assert rel.metric == 1234
  end

  # ---------------------------------------------------------------------------
  # (2) Cross-org isolation — OrgScope narrows; org B is invisible
  # ---------------------------------------------------------------------------

  test "cross-org: reading as org A returns ONLY org A's cohorts (org B invisible)" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    seed(org_a, "shared", 9, 100)
    seed(org_b, "shared", 9, 999_999)
    seed(org_b, "b_only", 9, 424_242)

    assert {:ok, rows} = Aggregate.read_all_for_org(Metric, org_actor(org_a), k: 5)

    # org A sees its own "shared" cohort with ITS value, and nothing of org B's.
    assert [%{kind: "shared", metric: 100}] = rows
    refute Enum.any?(rows, &(&1.metric == 999_999))
    refute Enum.any?(rows, &(&1.kind == "b_only"))
  end

  # ---------------------------------------------------------------------------
  # (3) Fail-closed guards
  # ---------------------------------------------------------------------------

  test "an org-LESS actor is refused BEFORE any row is read (fail closed)" do
    seed(Ash.UUID.generate(), "x", 9, 1)
    orgless = %{id: Ash.UUID.generate(), role: :member, plane: :tenant}
    assert {:error, :org_scope_required} = Aggregate.read_all_for_org(Metric, orgless, k: 5)
    # even the token-blind cross-tenant actor (no org_id) cannot reach the org path
    assert {:error, :org_scope_required} =
             Aggregate.read_all_for_org(Metric, Aggregate.actor(), k: 5)
  end

  test "a CROSS-tenant aggregate resource is refused on the org path (:not_org_scoped_aggregate)" do
    assert {:error, :not_org_scoped_aggregate} =
             Aggregate.read_all_for_org(CrossTenant, org_actor(Ash.UUID.generate()))
  end

  test "a non-aggregate resource is refused (:not_aggregate_resource)" do
    assert {:error, :not_aggregate_resource} =
             Aggregate.read_all_for_org(Enum, org_actor(Ash.UUID.generate()))
  end

  test "accepts a %Samen.Scope{} wrapper (unwraps to the org actor)" do
    org = Ash.UUID.generate()
    seed(org, "k", 9, 55)
    scope = %Samen.Scope{actor: org_actor(org)}
    assert {:ok, [%{metric: 55}]} = Aggregate.read_all_for_org(Metric, scope, k: 5)
  end

  # ---------------------------------------------------------------------------
  # Verifier org-scoped arm
  # ---------------------------------------------------------------------------

  test "verifier GREEN (anti-tautology): a real non-null org partition passes the org-scoped arm" do
    assert AggregatePrivacy.violations_for([Metric]) == []
  end

  test "verifier RED: an org-scoped resource with a NULLABLE org_id is flagged (no real partition)" do
    violations = AggregatePrivacy.violations_for([NoPartition])
    assert Enum.any?(violations, &(&1 =~ "NULLABLE `org_id`"))
    assert Enum.any?(violations, &(&1 =~ "NoPartition"))
  end

  test "verifier discriminator: only the no-partition resource is flagged for the org partition" do
    violations = AggregatePrivacy.violations_for([Metric, NoPartition])
    partition_flags = Enum.filter(violations, &(&1 =~ "org_id"))
    assert length(partition_flags) == 1
    assert hd(partition_flags) =~ "NoPartition"
  end
end
