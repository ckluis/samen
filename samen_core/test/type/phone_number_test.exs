defmodule Samen.Type.PhoneNumberTest do
  @moduledoc """
  H3 — `Samen.Type.PhoneNumber` (ADR-036 D3, T13 done-criterion 3, INV-1):
  the "H3 PII rule" mirror of `Samen.Type.EmailAddressTest` — a `PhoneNumber`
  attribute for **personal** use routes to the vault; a bare plaintext column
  is PII-by-default with NO type-level clearance.

  NOTE (framework behavior — FIXED in T99, ADR-036 D3 conformance): the vaulted
  write path now RE-RUNS the declared logical type's `cast_input/2` (validation
  AND normalization) before the plaintext reaches the vault. Previously
  `Samen.Transformers.MaterializePii` materialized every `pii_attribute` as
  `Samen.Type.VaultField` (identity cast) and `Samen.Vault.Change` only stringified,
  so the declared type's validation did NOT re-run on the vaulted path; T99 closed
  that gap in `Samen.Vault.Change` (see the D3-conformance addendum in
  docs/adr/ADR-036-rich-types.md and `Samen.Vault.CastValidationTest`). The
  personal-use test below therefore asserts reveal returns the NORMALIZED value
  (`"+15550100100"`) — byte-identical to what the org-plaintext path produces for the
  same input — not the raw input string.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Samen.Masked
  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias Samen.Type.PhoneNumber
  alias Samen.Vault
  alias SamenCore.Support.RichTypes.{OrgFixture, PersonalFixture}
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    :ok
  end

  describe "Ash.Type contract" do
    test "storage_type is :string" do
      assert PhoneNumber.storage_type([]) == :string
    end

    test "ACCEPT: an E.164-ish phone number, with common human separators normalized away" do
      assert PhoneNumber.cast_input("+15550100100", []) == {:ok, "+15550100100"}
      assert PhoneNumber.cast_input("+1 (555) 010-0100", []) == {:ok, "+15550100100"}
      assert PhoneNumber.cast_input("555-010-0100", []) == {:ok, "5550100100"}
    end

    test "REJECT: too short, leading zero, letters, blank" do
      assert PhoneNumber.cast_input("123", []) == :error
      assert PhoneNumber.cast_input("+0123456789", []) == :error
      assert PhoneNumber.cast_input("call-me-maybe", []) == :error
      assert PhoneNumber.cast_input("", []) == :error
      assert PhoneNumber.cast_input("   ", []) == :error
    end

    test "REJECT: over :max_length (checked pre-normalization)" do
      assert PhoneNumber.cast_input("+1 (555) 010-0100", max_length: 5) == :error
    end

    test "REJECT: non-string input never coerced" do
      assert PhoneNumber.cast_input(15_550_100_100, []) == :error
      assert PhoneNumber.cast_input(%{}, []) == :error
    end

    test "cast_input(nil) is nil" do
      assert PhoneNumber.cast_input(nil, []) == {:ok, nil}
    end

    test "cast_stored → dump_to_native round-trips" do
      {:ok, v} = PhoneNumber.cast_input("+1-555-010-0100", [])
      {:ok, native} = PhoneNumber.dump_to_native(v, [])
      assert native == "+15550100100"
      assert PhoneNumber.cast_stored(native, []) == {:ok, "+15550100100"}
    end

    test "dump_to_native(nil) is nil; a non-string is :error" do
      assert PhoneNumber.dump_to_native(nil, []) == {:ok, nil}
      assert PhoneNumber.dump_to_native(42, []) == :error
    end
  end

  describe "PII posture (ADR-036 D3) — PII-by-default, deliberately UNCLASSIFIED" do
    test "does NOT export samen_pii_class/0 (no type-level self-classification at all)" do
      refute function_exported?(PhoneNumber, :samen_pii_class, 0)
    end

    test "classify/1 falls through to the PII default; classified?/1 is false" do
      refute Classification.classified?(PhoneNumber)
      assert Classification.classify(PhoneNumber) == :pii
      assert Classification.pii?(PhoneNumber)
    end

    test "is NOT in the foundry-shipped TypeClearance manifest" do
      refute TypeClearance.cleared?(PhoneNumber)
      refute Enum.any?(TypeClearance.clearances(), &(&1.type == PhoneNumber))
    end

    test "SABOTAGE TWIN: a misconfigured host clearance naming this module has ZERO effect" do
      prior = Application.get_env(:samen_core, :non_pii_type_clearances)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:samen_core, :non_pii_type_clearances)
          _ -> Application.put_env(:samen_core, :non_pii_type_clearances, prior)
        end
      end)

      Application.put_env(:samen_core, :non_pii_type_clearances, [
        %{
          type: PhoneNumber,
          cleared_by: "careless-dev",
          reviewed_by: "careless-reviewer",
          reason: "attempting to blanket-clear phone — must have NO effect"
        }
      ])

      assert Classification.classify(PhoneNumber) == :pii
    end
  end

  describe "H3 personal-use rule (done-criterion 3, INV-1)" do
    test "personal use: pii_attribute vault: :pii_phone masks on read, reveals plaintext" do
      rec =
        PersonalFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          label: "grace",
          phone: "+1-555-010-0100"
        })
        |> Ash.create!()

      [read_back] =
        PersonalFixture
        |> Ash.Query.filter(id == ^rec.id)
        |> Ash.Query.ensure_selected([:phone])
        |> Ash.read!()

      assert %Masked{} = read_back.phone
      refute read_back.phone == "+1-555-010-0100"

      # T99 (ADR-036 D3): the vaulted write path re-runs PhoneNumber.cast_input, so
      # reveal returns the NORMALIZED number — identical to the org-plaintext path
      # (see OrgFixture.support_phone below and Samen.Vault.CastValidationTest).
      assert {:ok, "+15550100100"} = Vault.reveal(read_back.phone, TestRepo)
    end

    test "org-contact plaintext use round-trips, but TYPE stays :pii with no clearance" do
      rec =
        OrgFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          name: "acme",
          support_phone: "+1-555-010-0100"
        })
        |> Ash.create!()

      assert rec.support_phone == "+15550100100"
      assert Classification.classify(PhoneNumber) == :pii
    end
  end

  describe "catalog dump (done-criterion 4)" do
    test "Samen.Catalog.fields/1 dumps the type's OWN module name, never the primitive" do
      fields = OrgFixture |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})
      assert fields["support_phone"] == "Samen.Type.PhoneNumber"
    end
  end
end
