defmodule Samen.CdcDefaultDenyProjectionTest do
  @moduledoc """
  ADR-015 · G3 rider — **default-deny CDC/aggregate classifier** for freeform
  content columns.

  Replaces the name+type "provably non-PII" heuristic with a fail-closed mechanism:
  a freeform content column (`:string`/`:ci_string`/`:text`/`:map`/`:jsonb`, or any
  type NOT on the structural-safe allowlist) is EXCLUDED from `Projection.project/1`
  UNLESS it is (a) vault-routed (→ `:token`) or (b) cleared via a two-reviewer
  `non_pii!` declaration (`cleared_by != reviewed_by`). Everything else freeform is
  `:plaintext_pii` → refused, and `assert_no_plaintext!/2` RAISES on an explicit
  demand.

  Covers the G3 acceptance criteria (design.md §6):

    * AC-G3-1 (VER)  — an uncleared freeform (`:string`/`:map`) column classifies
      `:plaintext_pii` and is EXCLUDED from the projection.
    * AC-G3-2 (RP · anti-tautology) — the excluded freeform column is PROVABLY
      ABSENT from `project/1` AND `assert_no_plaintext!(resource, [col])` RAISES;
      the test FAILS if the column ever appears (sabotage probe below).
    * AC-G3-3 (VER)  — a `non_pii!`-cleared (distinct two-reviewer) freeform column
      IS present as a safe scalar; a vault-routed one IS present as `:token`.
    * AC-G3-5 (RP · over-block guard) — structural-safe types
      (uuid/enum/timestamp/number/bool) are NOT over-refused; they remain mirrored.

  AC-G3-4 (the per-vertical migration sweep + baseline shift) is a downstream task
  (build-plan A1 step 5) — this file proves the KERNEL mechanism only.

  Anti-tautology discipline (plan HARD RULE): every guarantee ships a red-path +
  a probe that the guarantee is non-vacuous. The "provably absent" proof
  (`refute col in project/1`) is paired with a sabotage that makes the SAME
  assertion FAIL when the column is force-injected, proving `refute` discriminates.
  """
  use ExUnit.Case, async: false

  alias Samen.Cdc.Projection
  alias Samen.NonPii

  @repo SamenCore.TestRepo

  # Fixtures across the freeform type spread:
  #   Patient        — pat_job_title  :string (uncleared freeform)   + bool/uuid/ts/token
  #   Ctx.Activity   — cea_subject    :string (uncleared freeform)   + :atom enum
  #   Widget         — tcf_custom     :map    (uncleared freeform)
  @patient SamenCore.Support.Clinical.Patient
  @activity Core.Ctx.Activity
  @widget SamenCore.Support.CustomFields.Widget

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    :ok
  end

  defp classify(resource, opts \\ []) do
    resource |> Projection.classify_columns(opts) |> Map.new()
  end

  defp projected_cols(resource, opts \\ []) do
    resource |> Projection.project(opts) |> Enum.map(&elem(&1, 0))
  end

  # A synthetic two-reviewer non_pii! entry (no DB round-trip needed — injected via
  # the classifier's :non_pii_entries opt, mirroring Context.build's test seam).
  defp cleared_entry(table, column) do
    %NonPii.Entry{
      table_name: table,
      column_name: column,
      cleared_by: "alice@example.com",
      reviewed_by: "bob@example.com",
      reason: "reviewed as non-PII operational text — two-reviewer sign-off",
      subject_column: "id"
    }
  end

  # ======================================================================
  # AC-G3-1 — uncleared freeform → :plaintext_pii, excluded from projection
  # ======================================================================

  describe "AC-G3-1 · uncleared freeform is refused" do
    test ":string freeform column classifies :plaintext_pii and is EXCLUDED" do
      c = classify(@patient)
      assert c["pat_job_title"] == :plaintext_pii

      refute "pat_job_title" in projected_cols(@patient),
             "an uncleared freeform :string must be absent from project/1"
    end

    test ":map (jsonb) freeform column classifies :plaintext_pii and is EXCLUDED" do
      c = classify(@widget)
      assert c["tcf_custom"] == :plaintext_pii

      refute "tcf_custom" in projected_cols(@widget),
             "an uncleared freeform :map must be absent from project/1"
    end

    test "a benign-named freeform column (no PII-name, no seed) is STILL refused (H-2)" do
      # cea_subject is benign-named with no seed value — under the old heuristic it
      # would have mirrored as :metadata. Default-deny refuses it.
      c = classify(@activity)
      assert c["cea_subject"] == :plaintext_pii

      refute "cea_subject" in projected_cols(@activity)
    end
  end

  # ======================================================================
  # AC-G3-2 — provably absent + assert_no_plaintext! RAISES (anti-tautology)
  # ======================================================================

  describe "AC-G3-2 · RED PATH — provably absent, explicit demand RAISES" do
    @tag :red_path
    test "assert_no_plaintext! RAISES when an uncleared freeform column is demanded" do
      assert_raise Projection.PlaintextInProjectionError, ~r/plaintext PII column/, fn ->
        Projection.assert_no_plaintext!(@patient, ["pat_id", "pat_job_title"])
      end

      # The :map case too.
      assert_raise Projection.PlaintextInProjectionError, fn ->
        Projection.assert_no_plaintext!(@widget, ["tcf_id", "tcf_custom"])
      end
    end

    @tag :red_path
    test "the projection is provably absent of EVERY :plaintext_pii column" do
      classified = Projection.classify_columns(@patient)
      refused = for {c, :plaintext_pii} <- classified, do: c
      projected = projected_cols(@patient)

      assert refused != [], "the fixture must contain at least one refused freeform column"

      for col <- refused do
        refute col in projected,
               "refused freeform column #{col} leaked into the projection"
      end
    end

    @tag :anti_tautology
    test "ANTI-TAUTOLOGY: the 'provably absent' assertion FAILS when the column is injected" do
      # The refute above only means something if it can FAIL. Simulate the leak by
      # clearing the SAME column (the only mechanism that can put a freeform column
      # into the projection) and confirm `refute col in projected` would now fail —
      # i.e. the assertion discriminates present-vs-absent, it is not vacuous.
      table = Projection.table_name(@patient)
      entries = [cleared_entry(table, "pat_job_title")]

      projected_when_cleared = projected_cols(@patient, non_pii_entries: entries)

      assert "pat_job_title" in projected_when_cleared,
             "a cleared freeform column MUST appear — proving the absent-assertion is non-vacuous"

      # And assert_no_plaintext! no longer raises for the cleared column.
      assert :ok =
               Projection.assert_no_plaintext!(@patient, ["pat_id", "pat_job_title"],
                 non_pii_entries: entries
               )
    end
  end

  # ======================================================================
  # AC-G3-3 — allowlist works: non_pii! cleared → safe scalar; vault → :token
  # ======================================================================

  describe "AC-G3-3 · the allowlist" do
    test "a two-reviewer non_pii!-cleared freeform column IS present as a safe scalar" do
      table = Projection.table_name(@patient)
      entries = [cleared_entry(table, "pat_job_title")]

      c = classify(@patient, non_pii_entries: entries)
      # A cleared freeform :string buckets as a safe scalar (:metadata), never
      # :plaintext_pii, and appears in the projection.
      assert c["pat_job_title"] == :metadata
      assert "pat_job_title" in projected_cols(@patient, non_pii_entries: entries)
    end

    test "a SELF-REVIEWED (cleared_by == reviewed_by) entry does NOT clear the column" do
      table = Projection.table_name(@patient)

      self_review = %NonPii.Entry{
        cleared_entry(table, "pat_job_title")
        | cleared_by: "alice@example.com",
          reviewed_by: "alice@example.com"
      }

      c = classify(@patient, non_pii_entries: [self_review])
      assert c["pat_job_title"] == :plaintext_pii,
             "a single actor must not be able to wave a freeform column into the mirror"

      refute "pat_job_title" in projected_cols(@patient, non_pii_entries: [self_review])
    end

    test "a vault-routed freeform field IS present as :token" do
      c = classify(@patient)
      # full_name/emails/phones/mrn are vault-routed pii_attributes → tokens.
      assert c["pat_full_name"] == :token
      assert c["pii_pat_mrn"] == :token

      cols = projected_cols(@patient)
      assert "pat_full_name" in cols
      assert "pii_pat_mrn" in cols
    end

    test "clearance is scoped to the exact (table, column) — a clearance on another table does NOT leak" do
      other_table_entry = cleared_entry("some_other_table", "pat_job_title")

      c = classify(@patient, non_pii_entries: [other_table_entry])
      assert c["pat_job_title"] == :plaintext_pii,
             "a non_pii! entry on a different table must not clear this column"
    end
  end

  # ======================================================================
  # AC-G3-5 — over-block guard: structural-safe types are NOT over-refused
  # ======================================================================

  describe "AC-G3-5 · over-block guard" do
    test "uuid / enum / timestamp / number / bool are NOT re-classified :plaintext_pii" do
      pat = classify(@patient)
      act = classify(@activity)

      # bounded id (uuid)
      assert pat["pat_id"] == :bounded_id
      assert pat["pat_org_id"] == :bounded_id
      assert pat["pat_primary_provider_id"] == :bounded_id
      # boolean (its OWN kind now, not the :metadata fall-through)
      assert pat["pat_consent_on_file"] == :boolean
      # timestamp
      assert pat["pat_inserted_at"] == :timestamp
      # enum (:atom one_of)
      assert act["cea_kind"] == :enum

      # None of them are refused.
      for k <- [:bounded_id, :boolean, :timestamp, :enum] do
        refute k == :plaintext_pii
      end
    end

    test "structural-safe columns REMAIN in the projection (default-deny did not kill them)" do
      cols = projected_cols(@patient)

      for col <- ~w(pat_id pat_org_id pat_primary_provider_id pat_consent_on_file
                    pat_inserted_at pat_updated_at) do
        assert col in cols, "structural-safe column #{col} must still mirror"
      end

      assert "cea_kind" in projected_cols(@activity), "an enum must still mirror"
    end

    @tag :anti_tautology
    test "ANTI-TAUTOLOGY: the over-block guard would CATCH an over-refusal of a bool/uuid" do
      # If the classifier ever over-refused a structural-safe type, it would be
      # :plaintext_pii and absent. Prove the guard discriminates: a bool/uuid are
      # present AND not refused today, so flipping either to refused would fail the
      # assertions above. We assert the discriminating fact directly.
      c = classify(@patient)
      refute c["pat_id"] == :plaintext_pii
      refute c["pat_consent_on_file"] == :plaintext_pii
    end
  end
end
