defmodule Samen.Type.EmailAddressTest do
  @moduledoc """
  H3 — `Samen.Type.EmailAddress` (ADR-036 D3, T13 done-criterion 3, INV-1):
  the "H3 PII rule" — declaring an `EmailAddress` attribute for **personal**
  use routes to the vault; a bare plaintext column is PII-by-default with NO
  type-level clearance (D3's structural "personal uses default to vault").

  Three halves:

    * `Ash.Type contract` — format-validation accept/reject vectors.
    * `PII posture` — proves this type is deliberately UNCLASSIFIED (falls
      through Classification.classify/1 to the mask-unknown-by-default PII
      result), carries NO type-level TypeClearance entry, and — the sabotage
      twin — that even a MISCONFIGURED host-supplied clearance naming this
      module has ZERO effect (the type never self-classifies `:non_pii`, so
      there is no config lever that flips it).
    * `H3 personal-use rule (done-criterion 3)` — the structural proof: a
      `pii_attribute :email, Samen.Type.EmailAddress, vault: :pii_email`
      round-trips through the vault (masked read, reveal gives plaintext back)
      — the ADR's "personal uses default to vault, refused as plaintext" made
      concrete against a real resource.

  NOTE (pre-existing framework behavior, out of T13's scope): `Samen.Vault.Change`
  / `Samen.Transformers.MaterializePii` materialize every `pii_attribute` as
  `Samen.Type.VaultField` regardless of its declared logical type, so this
  module's OWN `cast_input/2` format-validation does not currently re-run on
  the vaulted write path. The "Ash.Type contract" describe block proves the
  validation is correct when it IS invoked (a bare/plain attribute, or a
  direct `cast_input/2` call); the personal-use test below asserts the vault
  round-trip (mask-on-read / reveal), which this framework layer does perform.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Samen.Masked
  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias Samen.Type.EmailAddress
  alias Samen.Vault
  alias SamenCore.Support.RichTypes.{OrgFixture, PersonalFixture}
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    :ok
  end

  describe "Ash.Type contract" do
    test "storage_type is :string" do
      assert EmailAddress.storage_type([]) == :string
    end

    test "ACCEPT: a plausible email address" do
      assert EmailAddress.cast_input("grace@example.com", []) == {:ok, "grace@example.com"}
      assert EmailAddress.cast_input("  grace@example.com  ", []) == {:ok, "grace@example.com"}
    end

    test "REJECT: no @, no domain dot, blank, or whitespace-containing" do
      assert EmailAddress.cast_input("not-an-email", []) == :error
      assert EmailAddress.cast_input("grace@localhost", []) == :error
      assert EmailAddress.cast_input("", []) == :error
      assert EmailAddress.cast_input("   ", []) == :error
      assert EmailAddress.cast_input("grace @example.com", []) == :error
    end

    test "REJECT: over :max_length" do
      long = "grace@" <> String.duplicate("a", 100) <> ".com"
      assert EmailAddress.cast_input(long, max_length: 20) == :error
    end

    test "REJECT: non-string input never coerced" do
      assert EmailAddress.cast_input(42, []) == :error
      assert EmailAddress.cast_input(%{}, []) == :error
    end

    test "cast_input(nil) is nil" do
      assert EmailAddress.cast_input(nil, []) == {:ok, nil}
    end

    test "cast_stored → dump_to_native round-trips" do
      {:ok, v} = EmailAddress.cast_input("grace@example.com", [])
      {:ok, native} = EmailAddress.dump_to_native(v, [])
      assert native == "grace@example.com"
      assert EmailAddress.cast_stored(native, []) == {:ok, "grace@example.com"}
    end

    test "dump_to_native(nil) is nil; a non-string is :error" do
      assert EmailAddress.dump_to_native(nil, []) == {:ok, nil}
      assert EmailAddress.dump_to_native(42, []) == :error
    end
  end

  describe "PII posture (ADR-036 D3) — PII-by-default, UNCLASSIFIED" do
    test "does NOT export samen_pii_class/0" do
      refute function_exported?(EmailAddress, :samen_pii_class, 0)
    end

    test "classify/1 falls through to PII; classified?/1 is false" do
      refute Classification.classified?(EmailAddress)
      assert Classification.classify(EmailAddress) == :pii
      assert Classification.pii?(EmailAddress)
    end

    test "is NOT in the foundry-shipped TypeClearance manifest" do
      refute TypeClearance.cleared?(EmailAddress)
      refute Enum.any?(TypeClearance.clearances(), &(&1.type == EmailAddress))
    end

    test "SABOTAGE TWIN: a misconfigured host clearance naming this module has ZERO " <>
           "effect (no self-class to govern in the first place)" do
      prior = Application.get_env(:samen_core, :non_pii_type_clearances)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:samen_core, :non_pii_type_clearances)
          _ -> Application.put_env(:samen_core, :non_pii_type_clearances, prior)
        end
      end)

      Application.put_env(:samen_core, :non_pii_type_clearances, [
        %{
          type: EmailAddress,
          cleared_by: "careless-dev",
          reviewed_by: "careless-reviewer",
          reason: "attempting to blanket-clear email — must have NO effect"
        }
      ])

      # cleared?/1 may report true (a well-formed clearance entry exists), but
      # classify/1 MUST stay :pii — the gate is keyed on self_class == :non_pii,
      # which this type never claims.
      assert Classification.classify(EmailAddress) == :pii
    end
  end

  describe "H3 personal-use rule (done-criterion 3, INV-1)" do
    test "personal use: pii_attribute vault: :pii_email masks on read, reveals plaintext" do
      rec =
        PersonalFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          label: "grace",
          email: "grace@example.com"
        })
        |> Ash.create!()

      [read_back] =
        PersonalFixture
        |> Ash.Query.filter(id == ^rec.id)
        |> Ash.Query.ensure_selected([:email])
        |> Ash.read!()

      assert %Masked{} = read_back.email
      refute read_back.email == "grace@example.com"

      assert {:ok, "grace@example.com"} = Vault.reveal(read_back.email, TestRepo)
    end

    test "org-contact plaintext use round-trips, but TYPE stays :pii with no clearance " <>
           "(the plain-PII shape C4 pii_classify flags absent a NonPii.register entry)" do
      rec =
        OrgFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          name: "acme",
          support_email: "support@acme.example.com"
        })
        |> Ash.create!()

      assert rec.support_email == "support@acme.example.com"
      # The structural fact the verifier consults: this column's TYPE has no
      # governed non-PII clearance, so it is PII-by-default until a per-column
      # `Samen.NonPii.register/1` entry names (OrgFixture's table, :support_email).
      assert Classification.classify(EmailAddress) == :pii
    end
  end

  describe "catalog dump (done-criterion 4)" do
    test "Samen.Catalog.fields/1 dumps the type's OWN module name, never the primitive" do
      fields = OrgFixture |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})
      assert fields["support_email"] == "Samen.Type.EmailAddress"
    end
  end
end
