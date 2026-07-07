defmodule Samen.AggregatePrivacyVerifierTest do
  @moduledoc """
  T4.5 — `mix samen.verify.aggregate_privacy` red path: an aggregate-plane resource
  with NO fail-closed cohort spec fails the verifier. This turns the k-anon / l-div
  floors into a gated invariant — a new cross-tenant projection that forgot its cohort
  spec does not pass CI (otherwise it fails closed only at read time).

  Anti-tautology: a resource WITH a valid cohort spec passes (positive control), so the
  verifier is a discriminator, not an always-fail.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.AggregatePrivacy

  # An aggregate-plane resource WITH a valid cohort spec (compiles + passes).
  defmodule WithSpec do
    use Samen.Aggregate.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "aqp"

    postgres do
      table("aqp_with_spec")
      repo(SamenCore.TestRepo)
    end

    attributes do
      attribute(:tier, :string, public?: true)
      attribute(:tenant_count, :integer, public?: true)
      attribute(:mrr_cents, :integer, public?: true)
    end

    actions do
      defaults([:read])
    end

    def aggregate_cohort_spec do
      %Samen.Aggregate.CohortSpec{
        cohort_key_columns: [:tier],
        cohort_count_column: :tenant_count,
        value_columns: [:mrr_cents]
      }
    end
  end

  # An aggregate-plane resource with NO cohort spec (the red path).
  defmodule WithoutSpec do
    use Samen.Aggregate.Resource,
      otp_app: :samen_core,
      domain: nil,
      validate_domain_inclusion?: false,
      data_layer: AshPostgres.DataLayer,
      abbrev: "aqv"

    postgres do
      table("aqv_without_spec")
      repo(SamenCore.TestRepo)
    end

    attributes do
      attribute(:tier, :string, public?: true)
      attribute(:tenant_count, :integer, public?: true)
    end

    actions do
      defaults([:read])
    end

    # DELIBERATELY no aggregate_cohort_spec/0.
  end

  test "control (anti-tautology): a resource WITH a valid cohort spec passes the verifier" do
    assert AggregatePrivacy.violations_for([WithSpec]) == []
  end

  test "RED: an aggregate resource with NO cohort spec FAILS the verifier" do
    violations = AggregatePrivacy.violations_for([WithoutSpec])
    assert length(violations) == 1
    assert hd(violations) =~ "declares no fail-closed cohort spec"
    assert hd(violations) =~ "WithoutSpec"
  end

  test "the two together: only the specless resource is flagged" do
    violations = AggregatePrivacy.violations_for([WithSpec, WithoutSpec])
    assert length(violations) == 1
    assert hd(violations) =~ "WithoutSpec"
  end
end
