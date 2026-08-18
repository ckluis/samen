defmodule Samen.Type.URLTest do
  @moduledoc """
  H3 — `Samen.Type.URL` (ADR-036 D2/H3, T13 done-criteria 1 & 4): a
  scheme/host-validating absolute-URL scalar, non-PII BY DEFAULT — but see the
  `describe "personal-profile URL caveat (ADR-036 §3 H3)"` block, which proves
  the escape hatch for a personal-identifying URL (route it through a vaulted
  `pii_attribute`) works structurally despite the type's non-PII clearance.

  NOTE (pre-existing framework behavior, out of T13's scope): `Samen.Vault.Change`
  / `Samen.Transformers.MaterializePii` materialize every `pii_attribute` as
  `Samen.Type.VaultField` regardless of its declared logical type, so this
  module's OWN `cast_input/2` format-validation does not currently re-run on
  the vaulted write path. The "Ash.Type contract" describe block proves the
  validation is correct when it IS invoked (a bare/plain attribute, or a
  direct `cast_input/2` call); the personal-profile test below asserts the
  vault round-trip (mask-on-read / reveal), which this framework layer does
  perform.
  """
  use ExUnit.Case, async: false
  require Ash.Query

  alias Samen.Masked
  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias Samen.Type.URL
  alias Samen.Vault
  alias SamenCore.Support.RichTypes.{OrgFixture, PersonalFixture}
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    :ok
  end

  describe "Ash.Type contract" do
    test "storage_type is :string" do
      assert URL.storage_type([]) == :string
    end

    test "ACCEPT: an absolute http/https URL" do
      assert URL.cast_input("https://example.com/path?q=1", []) ==
               {:ok, "https://example.com/path?q=1"}

      assert URL.cast_input("http://example.com", []) == {:ok, "http://example.com"}
    end

    test "ACCEPT: a custom :schemes constraint allows a non-default scheme" do
      assert URL.cast_input("ftp://files.example.com/x", schemes: ["ftp"]) ==
               {:ok, "ftp://files.example.com/x"}
    end

    test "REJECT: a relative path (no scheme/host)" do
      assert URL.cast_input("/just/a/path", []) == :error
      assert URL.cast_input("not a url at all", []) == :error
    end

    test "REJECT: a scheme outside the allowlist (e.g. javascript:) even though it parses" do
      assert URL.cast_input("javascript:alert(1)", []) == :error
      assert URL.cast_input("ftp://files.example.com", []) == :error
    end

    test "REJECT: over :max_length" do
      long = "https://example.com/" <> String.duplicate("a", 100)
      assert URL.cast_input(long, max_length: 50) == :error
      assert {:ok, _} = URL.cast_input(long, max_length: 500)
    end

    test "REJECT: non-string input never coerced" do
      assert URL.cast_input(42, []) == :error
      assert URL.cast_input(%{}, []) == :error
    end

    test "cast_input(nil) is nil" do
      assert URL.cast_input(nil, []) == {:ok, nil}
    end

    test "cast_stored → dump_to_native round-trips" do
      {:ok, v} = URL.cast_input("https://example.com", [])
      {:ok, native} = URL.dump_to_native(v, [])
      assert native == "https://example.com"
      assert URL.cast_stored(native, []) == {:ok, "https://example.com"}
    end

    test "dump_to_native(nil) is nil; a non-string is :error" do
      assert URL.dump_to_native(nil, []) == {:ok, nil}
      assert URL.dump_to_native(42, []) == :error
    end
  end

  describe "PII posture (ADR-036 D2 / ADR-034 gate) — non-PII BY DEFAULT" do
    test "self-classifies :non_pii" do
      assert URL.samen_pii_class() == :non_pii
    end

    test "GREEN: classifies :non_pii on a FRESH host with NO configured clearances" do
      prior = Application.get_env(:samen_core, :non_pii_type_clearances)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:samen_core, :non_pii_type_clearances)
          _ -> Application.put_env(:samen_core, :non_pii_type_clearances, prior)
        end
      end)

      Application.put_env(:samen_core, :non_pii_type_clearances, [])

      assert TypeClearance.cleared?(URL)
      assert Classification.classify(URL) == :non_pii
      assert Classification.classified?(URL)
    end

    test "the shipped clearance is genuinely two-distinct-party (not self-reviewed)" do
      shipped = Enum.find(TypeClearance.clearances(), &(&1.type == URL))

      refute is_nil(shipped)
      assert shipped.cleared_by != shipped.reviewed_by
      assert is_binary(shipped.reason) and String.trim(shipped.reason) != ""
    end

    test "a bare plaintext URL column (org/non-personal use) round-trips as plaintext" do
      rec =
        OrgFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          name: "acme",
          website: "https://acme.example.com"
        })
        |> Ash.create!()

      assert rec.website == "https://acme.example.com"
    end
  end

  describe "personal-profile URL caveat (ADR-036 §3 H3)" do
    test "a personal-profile URL as a vaulted pii_attribute masks on read DESPITE " <>
           "the type's non-PII type-level clearance" do
      rec =
        PersonalFixture
        |> Ash.Changeset.for_create(:create, %{
          org_id: Ash.UUID.generate(),
          label: "grace",
          profile_url: "https://twitter.com/graceh"
        })
        |> Ash.create!()

      [read_back] =
        PersonalFixture
        |> Ash.Query.filter(id == ^rec.id)
        |> Ash.Query.ensure_selected([:profile_url])
        |> Ash.read!()

      assert %Masked{} = read_back.profile_url
      refute read_back.profile_url == "https://twitter.com/graceh"

      assert {:ok, "https://twitter.com/graceh"} = Vault.reveal(read_back.profile_url, TestRepo)
    end
  end

  describe "catalog dump (done-criterion 4)" do
    test "Samen.Catalog.fields/1 dumps the type's OWN module name, never the primitive" do
      fields = OrgFixture |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})
      assert fields["website"] == "Samen.Type.URL"
    end
  end
end
