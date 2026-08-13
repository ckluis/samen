defmodule Samen.CustomFields.ErasureTest do
  @moduledoc """
  ADR-046 §4.2 (D3) — the Tier-1 custom-bag erasure arm (`Samen.CustomFields.Erasure`).

  A `pii_declared: true` custom field stores PLAINTEXT PII in the sealed `custom` jsonb
  bag (never vault-routed), so crypto-shred (key destruction) does not reach it, and
  `Samen.NonPii` (whole-column) cannot redact one key of a many-key `:map`. This arm does
  **per-KEY** redaction: on shred it removes exactly the org's `pii_declared` keys from
  the subject's bag rows, leaving non-PII keys intact.

  Proven with anti-tautology positive controls:

    * REACHED — after erasure the subject's pii_declared bag key is GONE. Positive control:
      BEFORE erasure it was present (there was a real value to erase; not vacuous).
    * PER-KEY — a non-pii_declared key in the SAME bag SURVIVES (the arm is per-key, not
      whole-column / whole-bag).
    * ANTI-VACUITY — a DIFFERENT, non-erased subject's pii_declared key survives.
    * SHRED INTEGRATION — `Samen.Erasure.shred/2` runs the arm and reports the `custom_bag`
      tier (token-only counts).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.CustomFields
  alias Samen.CustomFields.Erasure, as: BagErasure
  alias Samen.Erasure
  alias SamenCore.Support.CustomFields.Widget
  alias SamenCore.TestRepo

  @table "tcf_widget"
  @spec_ %{
    table_name: @table,
    bag_column: "tcf_custom",
    subject_column: "tcf_id",
    org_column: "tcf_org_id"
  }
  @secret "alice@example.com"
  @plain "gold"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Samen.Kms.FileBacked.simulate_outage(false)

    on_exit(fn ->
      Samen.Kms.FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    end)

    :ok
  end

  defp define_bag!(org_id) do
    {:ok, _} =
      CustomFields.define_field(
        %{
          org_id: org_id,
          table_name: @table,
          field_name: "care_note",
          type: :string,
          pii_declared: true,
          erasure_specs: [@spec_]
        },
        TestRepo
      )

    {:ok, _} =
      CustomFields.define_field(
        %{org_id: org_id, table_name: @table, field_name: "loyalty_tier", type: :string},
        TestRepo
      )
  end

  defp create_widget!(org_id, custom) do
    {:ok, widget} =
      Widget
      |> Ash.Changeset.for_create(:create, %{name: "w", org_id: org_id, custom: custom},
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    widget
  end

  defp read_bag(id) do
    Widget
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(authorize?: false)
    |> Map.get(:custom)
  end

  test "REACHED + PER-KEY: erasure removes the pii_declared key, keeps the non-PII key" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    widget = create_widget!(org_id, %{"care_note" => @secret, "loyalty_tier" => @plain})

    # POSITIVE CONTROL (before erasure): the plaintext PII is present in the bag.
    before = read_bag(widget.id)
    assert before["care_note"] == @secret
    assert before["loyalty_tier"] == @plain

    assert [%{"resource" => @table, "rows_redacted" => 1, "keys_redacted" => 1}] =
             BagErasure.erase_subject(widget.id, TestRepo, custom_bag_specs: [@spec_])

    # REACHED: the pii_declared key is GONE. PER-KEY: the non-PII key survives.
    after_ = read_bag(widget.id)
    refute Map.has_key?(after_, "care_note")
    assert after_["loyalty_tier"] == @plain
  end

  test "ANTI-VACUITY: a different, non-erased subject's pii_declared key survives" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    erased = create_widget!(org_id, %{"care_note" => @secret, "loyalty_tier" => @plain})
    kept = create_widget!(org_id, %{"care_note" => "bob@example.com", "loyalty_tier" => @plain})

    assert [%{"rows_redacted" => 1}] =
             BagErasure.erase_subject(erased.id, TestRepo, custom_bag_specs: [@spec_])

    refute Map.has_key?(read_bag(erased.id), "care_note")
    # The other subject is untouched — erasure is subject-scoped, not table-wide.
    assert read_bag(kept.id)["care_note"] == "bob@example.com"
  end

  test "no spec registered → the arm is a no-op (returns [])" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    widget = create_widget!(org_id, %{"care_note" => @secret, "loyalty_tier" => @plain})

    assert [] = BagErasure.erase_subject(widget.id, TestRepo, custom_bag_specs: [])
    # Nothing removed.
    assert read_bag(widget.id)["care_note"] == @secret
  end

  test "Erasure.shred integration: the custom-bag arm runs and reports the custom_bag tier" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    widget = create_widget!(org_id, %{"care_note" => @secret, "loyalty_tier" => @plain})

    assert {:ok, %{report: report}} =
             Erasure.shred(widget.id, repo: TestRepo, org_id: org_id, custom_bag_specs: [@spec_])

    assert [%{"resource" => @table, "rows_redacted" => 1, "keys_redacted" => 1}] =
             report.tiers["custom_bag"]

    # The plaintext PII is actually gone from the bag; the non-PII key remains.
    after_ = read_bag(widget.id)
    refute Map.has_key?(after_, "care_note")
    assert after_["loyalty_tier"] == @plain
  end

  test "shred with NO custom-bag spec reports an empty custom_bag tier (arm present, no-op)" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    widget = create_widget!(org_id, %{"care_note" => @secret, "loyalty_tier" => @plain})

    assert {:ok, %{report: report}} = Erasure.shred(widget.id, repo: TestRepo, org_id: org_id)
    assert report.tiers["custom_bag"] == []
    # Un-erased: no spec means no redaction (the guard ensures a live pii_declared field
    # DOES have a spec; here we assert the arm's default is a clean no-op).
    assert read_bag(widget.id)["care_note"] == @secret
  end
end
