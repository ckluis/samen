defmodule Samen.AuditFreeformProjectionTest do
  @moduledoc """
  ADR-015 · migration step 1 — the `mix samen.audit.freeform_projection` sweep.

  The one-shot audit lists every freeform column the default-deny flip EXCLUDES
  from the CDC projection (`:plaintext_pii`), so the per-vertical triage
  (AC-G3-4) can decide vault-route / two-reviewer `non_pii!` / leave-excluded per
  column. The list must be exactly the projection's own refuse set — the audit
  and the enforcement share one classifier, so the audit cannot under-report.

  Guarantees proven here:

    * GREEN — an uncleared freeform column (string AND map) appears in the sweep
      with its table/column/resource/logical/type coordinates; structural-safe
      and vault-routed columns do NOT appear.
    * GREEN — a two-reviewer `non_pii!` clearance removes the column from the
      sweep (the triage's "allowlist" arm is visible to the audit).
    * RED PATH — a SELF-REVIEW clearance (`cleared_by == reviewed_by`) does NOT
      remove the column: the audit inherits the projection's distinct-party
      discipline, so a single actor cannot make a column vanish from the triage
      list. (Anti-tautology: sabotaging the distinct-reviewer filter makes this
      test FAIL — verified locally, see the A1 task report.)
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Audit.FreeformProjection
  alias Samen.NonPii

  @repo SamenCore.TestRepo

  # Same fixture spread as the default-deny projection suite:
  #   Patient — pat_job_title :string (uncleared freeform) + bool/uuid/ts/token
  #   Widget  — tcf_custom    :map    (uncleared freeform)
  @patient SamenCore.Support.Clinical.Patient
  @widget SamenCore.Support.CustomFields.Widget

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    :ok
  end

  defp entry(table, column, cleared_by, reviewed_by) do
    %NonPii.Entry{
      table_name: table,
      column_name: column,
      cleared_by: cleared_by,
      reviewed_by: reviewed_by,
      reason: "triage sign-off",
      subject_column: "id"
    }
  end

  defp excluded(resources, opts \\ []) do
    FreeformProjection.excluded_columns(resources, opts)
  end

  defp cols(excluded_list), do: Enum.map(excluded_list, & &1.column)

  test "sweep lists uncleared freeform columns with full coordinates (string + map)" do
    result = excluded([@patient, @widget])
    columns = cols(result)

    assert "pat_job_title" in columns
    assert "tcf_custom" in columns

    row = Enum.find(result, &(&1.column == "pat_job_title"))
    assert row.resource == @patient
    assert row.logical == :job_title
    assert is_binary(row.table)
  end

  test "sweep does NOT list structural-safe or vault-routed columns" do
    columns = cols(excluded([@patient]))

    # Structural-safe scalars mirror; vault-routed columns mirror as :token.
    # Neither belongs in the triage list.
    refute Enum.any?(columns, &String.ends_with?(&1, "_id"))
    refute Enum.any?(columns, &String.starts_with?(&1, "pii_"))
  end

  test "a two-reviewer non_pii! clearance removes the column from the sweep" do
    table = Samen.Cdc.Projection.table_name(@patient)
    opts = [non_pii_entries: [entry(table, "pat_job_title", "alice@x", "bob@x")]]

    refute "pat_job_title" in cols(excluded([@patient], opts)),
           "a validly-cleared column must drop off the triage list"
  end

  @tag :red_path
  test "RED PATH — a self-review clearance does NOT remove the column" do
    table = Samen.Cdc.Projection.table_name(@patient)
    opts = [non_pii_entries: [entry(table, "pat_job_title", "mallory@x", "mallory@x")]]

    assert "pat_job_title" in cols(excluded([@patient], opts)),
           "a self-review (cleared_by == reviewed_by) entry must NOT clear the column — " <>
             "the audit inherits the projection's distinct-party discipline"
  end
end
