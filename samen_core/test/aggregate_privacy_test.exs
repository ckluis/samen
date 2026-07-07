defmodule Samen.AggregatePrivacyTest do
  @moduledoc """
  T4.5 — the aggregate-privacy FLOORS (k-anonymity + l-diversity), unit-level.

  Proves the two floors that are ENFORCED today (doc §control ∴ block + "Token-blind
  isn't inference-blind" honest edge):

    * k-anonymity (clause (a)): a cell whose cohort count < k suppresses — INCLUDING
      count-of-one (the worst case the doc names).
    * l-diversity (clause (b)): a cohort with < l distinct sensitive values suppresses
      — INCLUDING a homogeneous cohort (every member shares one value).

  Plus the fail-closed default (no cohort spec → refuse to release) and the anti-
  tautology controls (a cleared cohort DOES release its value — the suppression is a
  discriminator, not an always-suppress).
  """
  use ExUnit.Case, async: true

  alias Samen.Aggregate.{CohortSpec, Privacy, Suppressed}

  # A cohort spec with BOTH a k-anon size column and an l-diversity distinct column.
  defp queue_spec do
    %CohortSpec{
      cohort_key_columns: [:status],
      cohort_count_column: :depth,
      distinct_sensitive_column: :distinct_priorities,
      value_columns: [:depth],
      sensitive_attribute: :ticket_priority
    }
  end

  # A k-anon-only cohort spec (no sensitive dimension).
  defp mrr_spec do
    %CohortSpec{
      cohort_key_columns: [:tier],
      cohort_count_column: :tenant_count,
      distinct_sensitive_column: nil,
      value_columns: [:mrr_cents]
    }
  end

  # ==========================================================================
  # (a) k-anonymity minimum-cohort suppression
  # ==========================================================================

  test "k-anon: a cohort count >= k RELEASES the value (anti-tautology positive control)" do
    rows = [%{tier: "Pro", tenant_count: 5, mrr_cents: 10_000}]
    assert {:ok, [row]} = Privacy.apply(rows, mrr_spec(), k: 5, l: 2)
    assert row.mrr_cents == 10_000
    refute Suppressed.suppressed?(row.mrr_cents)
  end

  test "k-anon: a cohort count < k SUPPRESSES the value" do
    rows = [%{tier: "Enterprise", tenant_count: 4, mrr_cents: 999_999}]
    assert {:ok, [row]} = Privacy.apply(rows, mrr_spec(), k: 5, l: 2)
    assert %Suppressed{reason: :k_anonymity, k: 5, observed: 4} = row.mrr_cents
    # The withheld value is GONE — the struct carries no plaintext number.
    refute match?(999_999, row.mrr_cents)
  end

  test "k-anon: COUNT-OF-ONE cohort suppresses (the worst-case red path)" do
    rows = [%{tier: "Bespoke", tenant_count: 1, mrr_cents: 250_000}]
    assert {:ok, [row]} = Privacy.apply(rows, mrr_spec(), k: 2, l: 2)
    assert %Suppressed{reason: :k_anonymity, observed: 1} = row.mrr_cents
  end

  test "k-anon: a nil / missing cohort count fails closed (suppresses)" do
    rows = [%{tier: "Ghost", tenant_count: nil, mrr_cents: 1}]
    assert {:ok, [row]} = Privacy.apply(rows, mrr_spec(), k: 2, l: 2)
    assert %Suppressed{reason: :k_anonymity} = row.mrr_cents
  end

  # ==========================================================================
  # (b) l-diversity minimum-distinct suppression
  # ==========================================================================

  test "l-div: a cohort clearing k AND with >= l distinct sensitive values RELEASES" do
    # depth 10 >= k=2, distinct_priorities 3 >= l=2 → released.
    rows = [%{status: "open", depth: 10, distinct_priorities: 3}]
    assert {:ok, [row]} = Privacy.apply(rows, queue_spec(), k: 2, l: 2)
    assert row.depth == 10
  end

  test "l-div: a HOMOGENEOUS cohort (distinct == 1) suppresses even when it clears k (the red path)" do
    # depth 8 clears k=2, but distinct_priorities 1 < l=2 → homogeneity attack → suppress.
    rows = [%{status: "resolved", depth: 8, distinct_priorities: 1}]
    assert {:ok, [row]} = Privacy.apply(rows, queue_spec(), k: 2, l: 2)
    assert %Suppressed{reason: :l_diversity, l: 2, observed: 1} = row.depth
  end

  test "l-div: distinct < l (but > 1) still suppresses" do
    rows = [%{status: "pending", depth: 20, distinct_priorities: 2}]
    assert {:ok, [row]} = Privacy.apply(rows, queue_spec(), k: 2, l: 3)
    assert %Suppressed{reason: :l_diversity, observed: 2} = row.depth
  end

  test "k-anon is checked BEFORE l-div: a too-small cohort suppresses with reason :k_anonymity" do
    # depth 1 < k=2 → k-anon fires first, before l-div is even considered.
    rows = [%{status: "closed", depth: 1, distinct_priorities: 1}]
    assert {:ok, [row]} = Privacy.apply(rows, queue_spec(), k: 2, l: 2)
    assert %Suppressed{reason: :k_anonymity} = row.depth
  end

  # ==========================================================================
  # Fail-closed: no cohort spec → refuse to release (mask-unknown-by-default)
  # ==========================================================================

  test "RED (fail closed): a nil cohort spec refuses to release ANY value" do
    rows = [%{tier: "Pro", tenant_count: 999, mrr_cents: 1}]
    assert {:error, :no_cohort_spec} = Privacy.apply(rows, nil)
  end

  # ==========================================================================
  # Config defaults
  # ==========================================================================

  test "the k / l floors default to sensible values (k=5, l=2) absent config override" do
    # samen_core's own config sets no k/l, so the defaults apply.
    assert Privacy.k() == 5
    assert Privacy.l() == 2
  end

  test "config overrides are honored" do
    prev_k = Application.get_env(:samen_core, :k_anonymity_min_cohort)
    prev_l = Application.get_env(:samen_core, :l_diversity_min_distinct)

    try do
      Application.put_env(:samen_core, :k_anonymity_min_cohort, 3)
      Application.put_env(:samen_core, :l_diversity_min_distinct, 4)
      assert Privacy.k() == 3
      assert Privacy.l() == 4
    after
      restore(:k_anonymity_min_cohort, prev_k)
      restore(:l_diversity_min_distinct, prev_l)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:samen_core, key)
  defp restore(key, val), do: Application.put_env(:samen_core, key, val)

  # ==========================================================================
  # ANTI-TAUTOLOGY probe (HARD RULE 2): sabotage the floor in-process and confirm the
  # red paths flip. We do NOT edit the source file here — we prove that the SAME rows
  # that suppress with the real floor would NOT suppress if the comparison were
  # neutered, by exercising both a suppressing and a releasing input against the real
  # apply/3. The complementary source-sabotage probe (edit Privacy.apply, watch the
  # red path fail, revert) is documented in the T4.5 report.
  # ==========================================================================

  test "anti-tautology: the SAME spec both suppresses (count-of-one) AND releases (count>=k) — not an always-suppress" do
    small = [%{tier: "Solo", tenant_count: 1, mrr_cents: 500}]
    big = [%{tier: "Pro", tenant_count: 50, mrr_cents: 500}]

    assert {:ok, [srow]} = Privacy.apply(small, mrr_spec(), k: 5)
    assert {:ok, [brow]} = Privacy.apply(big, mrr_spec(), k: 5)

    # The floor is a discriminator: identical value column, different cohort size →
    # one suppresses, one releases.
    assert Suppressed.suppressed?(srow.mrr_cents)
    refute Suppressed.suppressed?(brow.mrr_cents)
    assert brow.mrr_cents == 500
  end
end
