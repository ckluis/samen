defmodule Samen.CustomObjects.ErasureTest do
  @moduledoc """
  ADR-046 §8 residual #2 — the Tier-2 custom-OBJECT record-bag erasure rung
  (`Samen.CustomObjects.Erasure` + the `define_field/2` `tnt$obj$…` guard rung).

  A `pii_declared: true` custom-OBJECT field stores PLAINTEXT PII in the shared `tnt_record`
  attributes bag (never vault-routed), so crypto-shred (key destruction) does not reach it —
  the analogue of the Tier-1 first-class bag. Two guarantees close the escape E6 left open
  for custom OBJECTS:

    * GUARD — `define_field/2` (via `define_object_field/2`) REFUSES a pii_declared object
      field unless a `:record_bag_erasure_specs` arm covers the object, exactly as a
      first-class bag is refused unless a `:custom_bag_erasure_specs` arm covers its table.
      Anti-tautology: the SAME call is ALLOWED with the arm registered.
    * ARM — on shred of the subject a record references (via its opaque `refs`), the object's
      pii_declared keys are removed from that subject's `tnt_record` rows, per-KEY, leaving
      non-PII keys intact and other subjects untouched.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.CustomObjects
  alias Samen.CustomObjects.Erasure, as: RecordErasure
  alias Samen.CustomObjects.Record
  alias Samen.Erasure
  alias Samen.Scope
  alias SamenCore.TestRepo

  @object "contact_note"
  @spec_ %{object_key: @object, subject_ref_key: "subject"}
  @secret "alice@example.com"
  # A single non-PII-shaped token — the containment classifier rejects name/free-text-shaped
  # values on a non-pii_declared field, so keep the control value plainly non-PII.
  @plain "gold"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    Samen.Kms.FileBacked.simulate_outage(false)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
    Samen.Kms.FileBacked.init!()
  end

  defp scope_for(org_id), do: Scope.new(%{id: Ash.UUID.generate(), org_id: org_id, role: :admin})

  # Define the object + a pii_declared field (admissible only because the record-bag arm is
  # declared inline) + a non-PII field.
  defp define_bag!(org_id) do
    {:ok, _} = CustomObjects.define_object(%{org_id: org_id, object_key: @object}, TestRepo)

    {:ok, _} =
      CustomObjects.define_object_field(
        %{
          org_id: org_id,
          object_key: @object,
          field_name: "declared_email",
          type: :string,
          pii_declared: true,
          record_bag_specs: [@spec_]
        },
        TestRepo
      )

    {:ok, _} =
      CustomObjects.define_object_field(
        %{org_id: org_id, object_key: @object, field_name: "note", type: :string},
        TestRepo
      )

    :ok
  end

  defp create_record!(scope, subject_id) do
    {:ok, rec} =
      CustomObjects.create_record(
        scope,
        @object,
        %{"declared_email" => @secret, "note" => @plain},
        refs: %{"subject" => subject_id}
      )

    rec
  end

  defp read_attrs(id) do
    Record
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:attributes])
    |> Ash.read_one!(authorize?: false)
    |> Map.get(:attributes)
  end

  # ======================================================================
  # GUARD — the tnt$obj$ rung (anti-tautology: refuse without arm, allow with)
  # ======================================================================

  test "GUARD: a pii_declared custom-object field is REFUSED without a record-bag arm" do
    org_id = Ash.UUID.generate()
    {:ok, _} = CustomObjects.define_object(%{org_id: org_id, object_key: "uncovered"}, TestRepo)

    object_table = CustomObjects.object_table("uncovered")

    assert {:error, {:pii_declared_unerasable, ^object_table}} =
             CustomObjects.define_object_field(
               %{org_id: org_id, object_key: "uncovered", field_name: "e", type: :string, pii_declared: true},
               TestRepo
             )
  end

  test "GUARD anti-tautology: the SAME field is ALLOWED with a record-bag arm registered" do
    org_id = Ash.UUID.generate()
    {:ok, _} = CustomObjects.define_object(%{org_id: org_id, object_key: "covered"}, TestRepo)

    assert {:ok, _} =
             CustomObjects.define_object_field(
               %{
                 org_id: org_id,
                 object_key: "covered",
                 field_name: "e",
                 type: :string,
                 pii_declared: true,
                 record_bag_specs: [%{object_key: "covered", subject_ref_key: "subject"}]
               },
               TestRepo
             )

    # POSITIVE CONTROL: a NON-pii_declared field never needed an arm — always admissible.
    assert {:ok, _} =
             CustomObjects.define_object_field(
               %{org_id: org_id, object_key: "covered", field_name: "plain", type: :string},
               TestRepo
             )
  end

  # ======================================================================
  # ARM — per-key redaction reached via the record's refs subject
  # ======================================================================

  test "REACHED + PER-KEY: erasure removes the pii_declared record-bag key, keeps the non-PII key" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    scope = scope_for(org_id)
    subject = Ash.UUID.generate()
    rec = create_record!(scope, subject)

    # POSITIVE CONTROL (before erasure): the plaintext PII is present in the record bag.
    before = read_attrs(rec.id)
    assert before["declared_email"] == @secret
    assert before["note"] == @plain

    assert [%{"object_key" => @object, "rows_redacted" => 1, "keys_redacted" => 1}] =
             RecordErasure.erase_subject(subject, TestRepo, record_bag_specs: [@spec_])

    # REACHED: the pii_declared key is GONE. PER-KEY: the non-PII key survives.
    after_ = read_attrs(rec.id)
    refute Map.has_key?(after_, "declared_email")
    assert after_["note"] == @plain
  end

  test "ANTI-VACUITY: a different, non-erased subject's record-bag PII survives" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    scope = scope_for(org_id)
    erased = Ash.UUID.generate()
    kept = Ash.UUID.generate()
    erased_rec = create_record!(scope, erased)
    kept_rec = create_record!(scope, kept)

    assert [%{"rows_redacted" => 1}] =
             RecordErasure.erase_subject(erased, TestRepo, record_bag_specs: [@spec_])

    refute Map.has_key?(read_attrs(erased_rec.id), "declared_email")
    # The other subject's record is untouched — erasure is subject-scoped (via refs), not
    # object-table-wide.
    assert read_attrs(kept_rec.id)["declared_email"] == @secret
  end

  test "no spec registered → the arm is a no-op (returns [])" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    scope = scope_for(org_id)
    subject = Ash.UUID.generate()
    rec = create_record!(scope, subject)

    assert [] = RecordErasure.erase_subject(subject, TestRepo, record_bag_specs: [])
    assert read_attrs(rec.id)["declared_email"] == @secret
  end

  test "Erasure.shred integration: the record-bag arm runs and reports the record_bag tier" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    scope = scope_for(org_id)
    subject = Ash.UUID.generate()
    rec = create_record!(scope, subject)

    assert {:ok, %{report: report}} =
             Erasure.shred(subject, repo: TestRepo, org_id: org_id, record_bag_specs: [@spec_])

    assert [%{"object_key" => @object, "rows_redacted" => 1, "keys_redacted" => 1}] =
             report.tiers["record_bag"]

    after_ = read_attrs(rec.id)
    refute Map.has_key?(after_, "declared_email")
    assert after_["note"] == @plain
  end

  test "shred with NO record-bag spec reports an empty record_bag tier (arm present, no-op)" do
    org_id = Ash.UUID.generate()
    define_bag!(org_id)
    scope = scope_for(org_id)
    subject = Ash.UUID.generate()
    rec = create_record!(scope, subject)

    assert {:ok, %{report: report}} = Erasure.shred(subject, repo: TestRepo, org_id: org_id)
    assert report.tiers["record_bag"] == []
    assert read_attrs(rec.id)["declared_email"] == @secret
  end
end
