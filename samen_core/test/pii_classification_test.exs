defmodule Samen.PiiClassificationTest do
  @moduledoc """
  T1.3 (c) — the type classification registry with **MASK-UNKNOWN-BY-DEFAULT**
  (plan D9; vision doc §limits keystone "unknown types default to PII").

  The load-bearing guarantee here is the *default*: any type the registry has not
  explicitly cleared as `:non_pii` classifies as `:pii`. Coverage gaps fail SAFE.

  This file is the GREEN + property proof of that guarantee; the compile-time
  red path (a likely-PII composite type is not silently plain) lives in
  `Samen.PiiRedPathTest`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Samen.Pii.Classification

  # ==========================================================================
  # Known non-PII scalars are cleared (the ONLY types allowed plain without review)
  # ==========================================================================

  test "structurally non-PII scalars classify :non_pii and are `classified?`" do
    for t <- [:boolean, :integer, :float, :decimal, :uuid, :utc_datetime, :atom] do
      assert Classification.classify(t) == :non_pii,
             "expected #{inspect(t)} to be :non_pii"

      assert Classification.classified?(t),
             "expected #{inspect(t)} to be explicitly classified"
    end
  end

  test "the module-form of a known non-PII scalar also classifies :non_pii" do
    assert Classification.classify(Ash.Type.Boolean) == :non_pii
    assert Classification.classify(Ash.Type.UUID) == :non_pii
  end

  # ==========================================================================
  # Composite PII types self-classify :pii
  # ==========================================================================

  test "composite PII types (FullName/Emails/Phones) classify :pii" do
    for t <- [Samen.Type.FullName, Samen.Type.Emails, Samen.Type.Phones] do
      assert Classification.classify(t) == :pii, "expected #{inspect(t)} to be :pii"
      assert Classification.pii?(t)
    end
  end

  test "a host custom type self-classifying :pii is always honored (opt INTO protection)" do
    defmodule PiiSelf do
      def samen_pii_class, do: :pii
    end

    assert Classification.classify(PiiSelf) == :pii
    assert Classification.classified?(PiiSelf)
  end

  test "an UNGOVERNED :non_pii self-classification falls to :pii (fail-closed; ADR-034)" do
    # Opting a whole type OUT of masking is reviewer-gated. Without a valid
    # two-distinct-party clearance in Samen.NonPii.TypeClearance, a :non_pii
    # self-classification is NOT honored — it masks (PII), same as an unknown type.
    # The GOVERNED opt-out (with a clearance) is proven in Samen.PiiTypeClearanceTest.
    defmodule NonPiiSelfUngoverned do
      def samen_pii_class, do: :non_pii
    end

    assert Classification.classify(NonPiiSelfUngoverned) == :pii
    refute Classification.classified?(NonPiiSelfUngoverned)
  end

  # ==========================================================================
  # THE KEYSTONE — mask-unknown-by-default
  # ==========================================================================

  test "an unclassified/custom type the registry has never seen defaults to :pii" do
    # A bare module that is not an Ash type, does not self-classify, and is not in
    # the non-PII scalar allow-list. This is the "new %Passport{} type nobody
    # remembered to classify" case — it MUST default to PII, not plain.
    assert Classification.classify(Some.Brand.New.Passport.Type) == :pii
    refute Classification.classified?(Some.Brand.New.Passport.Type)
  end

  test ":string classifies :pii by default (it is NOT on the non-PII scalar list)" do
    # A raw :string is where free-form PII (ssn, email text, names) hides, so it is
    # deliberately NOT cleared as non-PII — it falls through to the default.
    assert Classification.classify(:string) == :pii
    refute Classification.classified?(:string)
  end

  test ":date and :ci_string are unclassified → :pii by default" do
    for t <- [:date, :ci_string] do
      assert Classification.classify(t) == :pii, "expected #{inspect(t)} :pii by default"
      refute Classification.classified?(t)
    end
  end

  test "the ONLY way to make an unknown type plain is a GOVERNED :non_pii opt-out" do
    # A bare :non_pii self-classification is no longer enough on its own — it must
    # be cleared by two distinct parties (ADR-034). Absent the clearance the type
    # masks. This keeps the opt-OUT lever a deliberate, reviewed decision, never an
    # accident — and now never a SINGLE-party one either.
    defmodule SelfClassOnly do
      def samen_pii_class, do: :non_pii
    end

    assert Classification.classify(SelfClassOnly) == :pii
  end

  # ==========================================================================
  # Property: no type escapes classification, and unknown always defaults PII
  # ==========================================================================

  # Arbitrary module names the registry has never heard of. None self-classify,
  # none are Ash non-PII scalars → every one must default to :pii.
  defp unknown_module do
    gen all(
          seg <- StreamData.string(?A..?Z, length: 1),
          rest <- StreamData.string(?a..?z, min_length: 1, max_length: 8)
        ) do
      Module.concat(["SamenPropUnknown", seg <> rest])
    end
  end

  property "∀ unknown module type → classify == :pii (mask-unknown-by-default)" do
    check all(mod <- unknown_module(), max_runs: 100) do
      assert Classification.classify(mod) == :pii
      refute Classification.classified?(mod)
    end
  end

  property "∀ type → classify/1 is total: always :pii or :non_pii, never crashes" do
    type_gen =
      StreamData.one_of([
        StreamData.member_of([
          :string,
          :boolean,
          :integer,
          :date,
          :uuid,
          Samen.Type.FullName,
          Samen.Type.Emails
        ]),
        unknown_module()
      ])

    check all(t <- type_gen, max_runs: 100) do
      assert Classification.classify(t) in [:pii, :non_pii]
    end
  end
end
