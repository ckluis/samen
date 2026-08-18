defmodule Samen.Type.AddressTest do
  @moduledoc """
  H4/H5 — `Samen.Type.Address` (ADR-036 D4, T14 done-criteria 1-3, INV-1):

    1. `Ash.Type` contract: composite cast/dump, PARTIAL addresses, the `country`
       format rule (the type's own validation boundary), catalog dump, and the
       CSV/JSON representation round trip.
    2. `pii_address`/`pii_dob` are live, routable vault classes (the "registry"
       probe — ADR-036 D4/D5: there is no central table, a vault class IS the
       `vault :name` declaration), plus the full `Samen.MaskingCase` 3-proof on
       an Address-typed attribute (INV-1).
    3. The ADR-036 §10 addendum's binding requirement (post-T99, prime-orchestrator
       ruling: option (b)): a garbage `Address` is refused AT ITS OWN INPUT
       BOUNDARY and CANNOT vault — the Address-analogue of the T13/T99
       garbage-email probe, paired with a positive control (anti-tautology).
  """
  use ExUnit.Case, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Masked
  alias Samen.NonPii.TypeClearance
  alias Samen.Pii.Classification
  alias Samen.Pii.Info, as: PiiInfo
  alias Samen.Type.Address
  alias Samen.Vault
  alias SamenCore.Support.RichTypes.{OrgFixture, PersonalFixture}
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    :ok
  end

  defp create(attrs) do
    PersonalFixture
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: Ash.UUID.generate()}, attrs))
    |> Ash.create()
  end

  defp create!(attrs) do
    PersonalFixture
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: Ash.UUID.generate()}, attrs))
    |> Ash.create!()
  end

  defp read_all do
    PersonalFixture |> Ash.Query.ensure_selected([:address]) |> Ash.read!()
  end

  # ==========================================================================
  # Ash.Type contract (done-criterion 1)
  # ==========================================================================

  describe "Ash.Type contract" do
    test "storage_type is :map and it self-classifies :pii" do
      assert Address.storage_type([]) == :map
      assert Address.samen_pii_class() == :pii
    end

    test "ACCEPT: a full address, atom-keyed and string-keyed maps, and a struct all cast identically" do
      expected = %Address{
        line1: "123 Main St",
        line2: "Apt 4",
        city: "Springfield",
        region: "IL",
        postal_code: "62704",
        country: "US"
      }

      assert Address.cast_input(expected, []) == {:ok, expected}

      assert Address.cast_input(
               %{
                 line1: "123 Main St",
                 line2: "Apt 4",
                 city: "Springfield",
                 region: "IL",
                 postal_code: "62704",
                 country: "US"
               },
               []
             ) == {:ok, expected}

      assert Address.cast_input(
               %{
                 "line1" => "123 Main St",
                 "line2" => "Apt 4",
                 "city" => "Springfield",
                 "region" => "IL",
                 "postal_code" => "62704",
                 "country" => "US"
               },
               []
             ) == {:ok, expected}
    end

    test "ACCEPT: a PARTIAL address (only some fields set) casts fine — every field is optional" do
      assert Address.cast_input(%{city: "Springfield", country: "US"}, []) ==
               {:ok, %Address{city: "Springfield", country: "US"}}

      assert Address.cast_input(%{}, []) == {:ok, %Address{}}
    end

    test "ACCEPT: country is normalized — trimmed + upcased to the ISO-3166-1 alpha-2 form" do
      assert {:ok, %Address{country: "US"}} = Address.cast_input(%{country: "us"}, [])
      assert {:ok, %Address{country: "GB"}} = Address.cast_input(%{country: "  gb  "}, [])
    end

    test "cast_input(nil) is nil" do
      assert Address.cast_input(nil, []) == {:ok, nil}
    end

    test "REJECT: a non-map/non-struct top-level value never coerced" do
      assert Address.cast_input("123 Main St, Springfield, IL", []) == :error
      assert Address.cast_input(42, []) == :error
      assert Address.cast_input([1, 2, 3], []) == :error
    end

    test "REJECT: a field present with the wrong shape is refused, never stringified" do
      assert Address.cast_input(%{city: 12_345}, []) == :error
      assert Address.cast_input(%{line1: true}, []) == :error
      assert Address.cast_input(%{postal_code: %{}}, []) == :error
    end

    test "REJECT: country not a two-letter alpha-2 country code (shape check, not ISO-3166-1 set membership) — the garbage-Address vector" do
      # The exact vector this ADR-036 §10 addendum's write-boundary red test uses
      # (see the vault section below and Samen.Vault.CastValidationTest).
      assert Address.cast_input(%{country: "USA"}, []) == :error
      assert Address.cast_input(%{country: "1"}, []) == :error
      assert Address.cast_input(%{country: "12"}, []) == :error
      assert Address.cast_input(%{country: ""}, []) == :error
      assert Address.cast_input(%{country: "!!"}, []) == :error
    end

    test "dump → cast_stored round-trips (full and partial)" do
      full = %Address{
        line1: "123 Main St",
        line2: nil,
        city: "Springfield",
        region: "IL",
        postal_code: "62704",
        country: "US"
      }

      {:ok, native} = Address.dump_to_native(full, [])

      assert native == %{
               "line1" => "123 Main St",
               "line2" => nil,
               "city" => "Springfield",
               "region" => "IL",
               "postal_code" => "62704",
               "country" => "US"
             }

      assert Address.cast_stored(native, []) == {:ok, full}

      partial = %Address{city: "Springfield", country: "US"}
      {:ok, partial_native} = Address.dump_to_native(partial, [])
      assert Address.cast_stored(partial_native, []) == {:ok, partial}
    end

    test "dump_to_native(nil) is nil; a non-struct is :error" do
      assert Address.dump_to_native(nil, []) == {:ok, nil}
      assert Address.dump_to_native(%{line1: "x"}, []) == :error
      assert Address.dump_to_native("not an address", []) == :error
    end

    test "cast_stored(nil) is nil; a non-map is :error" do
      assert Address.cast_stored(nil, []) == {:ok, nil}
      assert Address.cast_stored("garbage", []) == :error
    end
  end

  # ==========================================================================
  # PII classification — ALWAYS :pii, no gate (ADR-036 D4)
  # ==========================================================================

  describe "PII posture (ADR-036 D4) — ALWAYS PII, unconditionally self-classified" do
    test "classify/1 is :pii; classified?/1 is true (self-classification, no clearance needed)" do
      assert Classification.classify(Address) == :pii
      assert Classification.classified?(Address)
      assert Classification.pii?(Address)
    end

    test "is NOT in the foundry-shipped TypeClearance manifest (Address has no plain/cleared path)" do
      refute TypeClearance.cleared?(Address)
      refute Enum.any?(TypeClearance.clearances(), &(&1.type == Address))
    end

    test "SABOTAGE TWIN: a misconfigured host clearance naming Address has ZERO effect" do
      # Unlike EmailAddress/PhoneNumber (which are PII by DEFAULT but unclassified —
      # a governed clearance could theoretically be added for them), Address
      # self-classifies :pii directly (Classification precedence #1), which always
      # wins BEFORE any :non_pii clearance is even consulted. This proves that
      # structurally: even a clearance naming Address has no effect.
      prior = Application.get_env(:samen_core, :non_pii_type_clearances)

      on_exit(fn ->
        case prior do
          nil -> Application.delete_env(:samen_core, :non_pii_type_clearances)
          _ -> Application.put_env(:samen_core, :non_pii_type_clearances, prior)
        end
      end)

      Application.put_env(:samen_core, :non_pii_type_clearances, [
        %{
          type: Address,
          cleared_by: "careless-dev",
          reviewed_by: "careless-reviewer",
          reason: "attempting to blanket-clear Address — must have NO effect"
        }
      ])

      assert Classification.classify(Address) == :pii
    end
  end

  # ==========================================================================
  # Catalog dump (done-criterion 1)
  # ==========================================================================

  describe "catalog dump (done-criterion 1)" do
    test "Samen.Catalog.fields/1 dumps the type's OWN module name, never the primitive" do
      fields = OrgFixture |> Samen.Catalog.fields() |> Map.new(&{&1.logical_name, &1.type})
      assert fields["billing_address"] == "Samen.Type.Address"
    end
  end

  # ==========================================================================
  # CSV / JSON representation round trip (done-criterion 1, ADR-036 D5 H7 row:
  # "Address … JSON object"). samen_core does not depend on samen_web's Csv
  # module, so this proves the CONTRACT the Csv `cell/1` generic map/JSON clause
  # relies on: dump_to_native produces a plain JSON-encodable map, and cast_input
  # accepts the round-tripped decode back — the same shape `decode_cell/1` hands
  # to a governed action's cast_input on import.
  # ==========================================================================

  describe "CSV/JSON representation round trip (done-criterion 1)" do
    test "dump_to_native → Jason.encode! → Jason.decode! → cast_input round-trips a full address" do
      original = %Address{
        line1: "1600 Amphitheatre Pkwy",
        line2: nil,
        city: "Mountain View",
        region: "CA",
        postal_code: "94043",
        country: "US"
      }

      {:ok, native} = Address.dump_to_native(original, [])
      json = Jason.encode!(native)
      decoded = Jason.decode!(json)

      assert Address.cast_input(decoded, []) == {:ok, original}
    end

    test "the same round trip holds for a PARTIAL address" do
      original = %Address{city: "Mountain View", country: "US"}
      {:ok, native} = Address.dump_to_native(original, [])
      decoded = native |> Jason.encode!() |> Jason.decode!()

      assert Address.cast_input(decoded, []) == {:ok, original}
    end
  end

  # ==========================================================================
  # Vault class registry probe (done-criterion 2): pii_address + pii_dob are
  # live, routable vaults. Per ADR-036 D4/D5 there is no central registry table —
  # a "vault class" IS a `vault :name` declaration + a `pii_attribute` routing to
  # it, which `SamenCore.Support.RichTypes.PersonalFixture` now carries for both.
  # ==========================================================================

  describe "pii_address + pii_dob are present in the vault class registry (done-criterion 2)" do
    test "PersonalFixture declares both vaults, routable via Samen.Pii.Info" do
      vaults = PiiInfo.vaults(PersonalFixture)
      assert :pii_address in vaults
      assert :pii_dob in vaults
    end

    test "the :address field is a COMPOSITE vault-routed field routed to :pii_address" do
      field = PersonalFixture |> PiiInfo.fields() |> Enum.find(&(&1.name == :address))

      refute is_nil(field)
      assert field.type == Address
      assert field.vault == :pii_address
      assert field.composite? == true
      # Composite routing convention (ADR-036 D4): no `pii_` column prefix.
      assert to_string(field.storage_name) == "srp_address"
    end

    test "the :dob field is a SCALAR vault-routed field routed to :pii_dob (H5 formalization)" do
      field = PersonalFixture |> PiiInfo.fields() |> Enum.find(&(&1.name == :dob))

      refute is_nil(field)
      assert field.type == :date
      assert field.vault == :pii_dob
      assert field.composite? == false
      # Scalar routing convention: the pii_ prefix.
      assert to_string(field.storage_name) == "pii_srp_dob"
    end
  end

  # ==========================================================================
  # ADR-036 §10 addendum (binding, post-T99, prime-orchestrator option (b)):
  # Address is validated AT ITS OWN INPUT BOUNDARY on the vaulted write path — a
  # malformed Address cannot vault. Permanent RED test + POSITIVE CONTROL
  # (anti-tautology), the Address analogue of the T13/T99 garbage-email probe.
  # The permanent home for the vault-write-path assertions lives alongside T99's
  # in `Samen.Vault.CastValidationTest`; these repeat the two load-bearing
  # vectors here so the type's own test file is a complete, self-contained proof.
  # ==========================================================================

  describe "RED (permanent) — a malformed Address must NOT vault (ADR-036 §10 addendum)" do
    test "a garbage country (\"USA\", 3 letters) is REFUSED — Ash.create errors, DB unchanged" do
      assert {:error, %Ash.Error.Invalid{}} =
               create(%{label: "garbage-address", address: %{country: "USA"}})

      refute Enum.any?(read_all(), &(&1.label == "garbage-address"))
    end

    test "a wrong-shaped field (city as an integer) is REFUSED — Ash.create errors, DB unchanged" do
      assert {:error, %Ash.Error.Invalid{}} =
               create(%{label: "garbage-shape", address: %{city: 12_345}})

      refute Enum.any?(read_all(), &(&1.label == "garbage-shape"))
    end

    test "POSITIVE CONTROL (anti-tautology): a VALID Address on the same attribute vaults fine" do
      assert {:ok, rec} =
               create(%{
                 label: "valid-address",
                 address: %{line1: "123 Main St", city: "Springfield", country: "us"}
               })

      assert %Masked{} = Enum.find(read_all(), &(&1.id == rec.id)).address
    end
  end

  describe "the vaulted Address value is CAST/NORMALIZED before it is stored (own-boundary parity)" do
    test "reveal returns the NORMALIZED (uppercased country) address, not the raw input" do
      rec =
        create!(%{
          label: "normalize-me",
          address: %{line1: "1 Infinite Loop", city: "Cupertino", country: "  us  "}
        })

      [read_back] =
        PersonalFixture
        |> Ash.Query.filter(id == ^rec.id)
        |> Ash.Query.ensure_selected([:address])
        |> Ash.read!()

      assert %Masked{} = read_back.address
      assert {:ok, revealed_json} = Vault.reveal(read_back.address, TestRepo)

      assert Jason.decode!(revealed_json) == %{
               "line1" => "1 Infinite Loop",
               "line2" => nil,
               "city" => "Cupertino",
               "region" => nil,
               "postal_code" => nil,
               "country" => "US"
             }
    end
  end

  # ==========================================================================
  # The full Samen.MaskingCase 3-proof (INV-1, done-criterion 2): GREEN (tenant
  # clear) / RED (operator masked) / SABOTAGE twin (refutable leak scan).
  # ==========================================================================

  describe "MaskingCase 3-proof on an Address-typed attribute (INV-1)" do
    setup do
      rec =
        create!(%{
          label: "masking-proof",
          address: %{line1: "42 Wallaby Way", city: "Sydney", country: "au"}
        })

      [read_back] =
        PersonalFixture
        |> Ash.Query.filter(id == ^rec.id)
        |> Ash.Query.ensure_selected([:address])
        |> Ash.read!()

      %{record: read_back}
    end

    test "GREEN — the tenant plane resolves the Address CLEAR (not %Masked{})", %{record: record} do
      resolved = resolve_on_plane(record, PersonalFixture, :tenant, repo: TestRepo)

      refute match?(%Masked{}, resolved.address)

      assert Jason.decode!(resolved.address) == %{
               "line1" => "42 Wallaby Way",
               "line2" => nil,
               "city" => "Sydney",
               "region" => nil,
               "postal_code" => nil,
               "country" => "AU"
             }
    end

    test "RED — the operator (impersonation, no grant) plane resolves %Masked{} (••••), never plaintext/token",
         %{record: record} do
      resolved = resolve_on_plane(record, PersonalFixture, :operator, repo: TestRepo)

      assert_plane_masked!(resolved.address)
      refute to_string(resolved.address) =~ "Wallaby"
      refute to_string(resolved.address) =~ "Sydney"
    end

    test "SABOTAGE twin — the leak scan is refutable: a deliberately-leaked render IS caught",
         %{record: record} do
      resolved = resolve_on_plane(record, PersonalFixture, :tenant, repo: TestRepo)
      plaintext = resolved.address

      # A correctly-masked "render" (what the operator plane actually produces)
      # passes the scan: the plaintext is absent.
      masked_render = "address: #{Samen.MaskingCase.mask()}"
      refute masked_render =~ "Wallaby"

      # A modeled BROKEN render (e.g. a resolver bug that leaked the tenant-plane
      # value into an operator-facing surface) IS detected by the SAME scan —
      # proving the red assertion above is refutable, not a tautology.
      leaked_render = "address: #{plaintext}"
      assert_leak_detected!(leaked_render, "Wallaby")
    end
  end
end
