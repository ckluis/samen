defmodule Samen.ResourceTest do
  @moduledoc """
  T1.1 acceptance: `Samen.Resource` under the production API.

  Covers: self-qualifying storage (every column prefixed), the S0.2 caveat-F1 FK
  ordering fix (synthesized FKs prefixed AND targeting the composed table),
  injected universal columns, the first-class `samen`-section abbrev introspection,
  fragment single-table composition (no INHERITS), and end-to-end create/read.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Resource.Info
  alias SamenCore.Support.Clinical.Patient
  alias SamenCore.Support.Clinical.Staff
  alias SamenCore.Support.Crm.Company
  alias SamenCore.Support.Crm.Contact
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
  end

  defp sources(resource), do: Map.new(Info.attributes(resource), &{&1.name, &1.source})

  defp domain_migration_ddl do
    [path] =
      Path.wildcard(Path.join([__DIR__, "..", "priv", "test_repo", "migrations", "*_initial_core.exs"]))

    File.read!(path)
  end

  # ==========================================================================
  # Self-qualifying storage: every physical column carries the resource abbrev
  # ==========================================================================

  test "user attributes are prefixed with the resource abbrev, logical names untouched" do
    com = sources(Contact)
    assert com[:name] == :com_name

    names = Enum.map(Info.attributes(Contact), & &1.name)
    assert :name in names
    refute :com_name in names
  end

  test "the abbrev is introspectable via the first-class samen section (F4)" do
    assert Samen.Info.abbrev(Contact) == "com"
    assert Samen.Info.abbrev(Company) == "cpy"
    assert Samen.Info.abbrev(Patient) == "pat"
    assert Samen.Info.abbrev(Staff) == "stf"
  end

  # ==========================================================================
  # Injected universal columns id/org_id/inserted_at/updated_at — all prefixed
  # ==========================================================================

  test "id/org_id/inserted_at/updated_at are injected and prefixed on every resource" do
    for {resource, abbrev} <- [{Contact, "com"}, {Company, "cpy"}, {Patient, "pat"}, {Staff, "stf"}] do
      src = sources(resource)

      for field <- [:id, :org_id, :inserted_at, :updated_at] do
        assert src[field] == :"#{abbrev}_#{field}",
               "expected #{abbrev}_#{field} on #{inspect(resource)}, got #{inspect(src[field])}"
      end
    end
  end

  test "the injected id is the primary key" do
    pk = Info.primary_key(Contact)
    assert pk == [:id]
  end

  # ==========================================================================
  # FK ordering fix (S0.2 caveat F1): synthesized FKs are prefixed AND target the
  # composed table's prefixed PK
  # ==========================================================================

  test "belongs_to FK attribute is prefixed (com_company_id, not company_id)" do
    src = sources(Contact)
    assert src[:company_id] == :com_company_id
    refute :company_id in Enum.map(Info.attributes(Contact), & &1.source)
  end

  test "generated DDL: FK column is prefixed and references the composed table's prefixed PK" do
    ddl = domain_migration_ddl()
    assert ddl =~ ":com_company_id"
    assert ddl =~ "references(:cpy_company"
    assert ddl =~ "column: :cpy_id"

    assert ddl =~ ":pat_primary_provider_id"
    assert ddl =~ "references(:stf_staff"
    assert ddl =~ "column: :stf_id"
  end

  test "generated DDL: injected timestamps and org_id are prefixed columns" do
    ddl = domain_migration_ddl()

    for col <- ~w(com_id com_org_id com_inserted_at com_updated_at cpy_org_id stf_org_id) do
      assert ddl =~ ":#{col}", "expected #{col} in generated DDL"
    end
  end

  # ==========================================================================
  # Fragment single-table composition (S0.3) under the prod macro
  # ==========================================================================

  test "each composed resource maps to exactly ONE physical table" do
    assert AshPostgres.DataLayer.Info.table(Patient) == "pat_patient"
    assert AshPostgres.DataLayer.Info.table(Staff) == "stf_staff"
  end

  test "the fragment Core.Person is NOT a resource and has no table" do
    refute Ash.Resource.Info.resource?(Core.Person)
    assert function_exported?(Core.Person, :extensions, 0)
    assert Samen.Pii in Core.Person.extensions()
    assert Samen.Catalog in Core.Person.extensions()
  end

  test "fragment attributes inherit the composing resource's abbrev" do
    pat = sources(Patient)
    stf = sources(Staff)

    assert pat[:job_title] == :pat_job_title
    assert stf[:job_title] == :stf_job_title

    for field <- [:full_name, :emails, :phones] do
      assert pat[field] == :"pat_#{field}"
      assert stf[field] == :"stf_#{field}"
    end
  end

  test "scalar pii_attribute declarations carry the pii_ prefix (pii_<abbrev>_<name>)" do
    pat = sources(Patient)
    # Vision doc §core PII routing note: scalar pii_attribute fields carry the
    # pii_ prefix (pii_pat_dob, pii_pat_mrn), UNLIKE composite fields.
    assert pat[:dob] == :pii_pat_dob
    assert pat[:mrn] == :pii_pat_mrn
  end

  test "belongs_to :primary_provider resolves to the Staff resource (a real table)" do
    rel = Info.relationship(Patient, :primary_provider)
    assert rel.destination == Staff
    refute rel.destination == Core.Person
  end

  test "generated DDL contains NO INHERITS anywhere" do
    ddl_files =
      Path.wildcard(Path.join([__DIR__, "..", "priv", "test_repo", "migrations", "*.exs"]))

    assert ddl_files != []

    for f <- ddl_files do
      refute File.read!(f) =~ ~r/inherits/i, "INHERITS found in #{f}"
    end
  end

  test "the LIVE database schema uses no table inheritance (pg_inherits is empty)" do
    %{rows: [[count]]} = TestRepo.query!("SELECT count(*) FROM pg_inherits", [])
    assert count == 0

    %{rows: rows} =
      TestRepo.query!(
        "SELECT relname, relkind, relhassubclass FROM pg_class WHERE relname = ANY($1)",
        [["pat_patient", "stf_staff", "com_contact", "cpy_company"]]
      )

    by_name = Map.new(rows, fn [name, kind, hassub] -> {name, {kind, hassub}} end)
    assert by_name["pat_patient"] == {"r", false}
    assert by_name["stf_staff"] == {"r", false}
    assert by_name["com_contact"] == {"r", false}
    assert by_name["cpy_company"] == {"r", false}
  end

  # ==========================================================================
  # End-to-end: prefixed storage + prefixed FK + injected columns all work
  # ==========================================================================

  test "create + FK + read round-trips through prefixed columns (plain resources)" do
    org_id = Ash.UUID.generate()

    company =
      Company
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "Acme"})
      |> Ash.create!()

    contact =
      Contact
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, name: "Ada", company_id: company.id})
      |> Ash.create!()

    assert contact.company_id == company.id

    # The physical columns really are prefixed: query the source names directly.
    %{rows: [[name, stored_org, ins, upd]]} =
      TestRepo.query!(
        "SELECT com_name, com_org_id, com_inserted_at, com_updated_at FROM com_contact WHERE com_id = $1",
        [Ecto.UUID.dump!(contact.id)]
      )

    assert name == "Ada"
    assert Ecto.UUID.load!(stored_org) == org_id
    assert %NaiveDateTime{} = ins
    assert %NaiveDateTime{} = upd

    # Read back through the logical names and confirm injected columns round-trip.
    [read_back] =
      Contact
      |> Ash.Query.filter(id == ^contact.id)
      |> Ash.Query.ensure_selected([:org_id, :inserted_at, :updated_at])
      |> Ash.read!()

    assert read_back.name == "Ada"
    assert read_back.company_id == company.id
    assert read_back.org_id == org_id
    assert %DateTime{} = read_back.inserted_at
    assert %DateTime{} = read_back.updated_at
  end

  test "create + FK + read round-trips across composed (fragment) tables" do
    org_id = Ash.UUID.generate()

    staff =
      Staff
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        license_no: "MD-1",
        full_name: %{first: "Ada", last: "Lovelace"},
        job_title: "Physician"
      })
      |> Ash.create!()

    patient =
      Patient
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        full_name: %{first: "Grace", last: "Hopper"},
        job_title: "patient",
        dob: ~D[1906-12-09],
        mrn: "MRN-9",
        primary_provider_id: staff.id
      })
      |> Ash.create!()

    assert patient.primary_provider_id == staff.id

    # Vault-stack fix: PII is vault-routed, so filter on a NON-PII column
    # (primary_provider_id) — the plaintext MRN no longer lives in the column to
    # filter on (it's a `vt_*` token). This proves the FK + read round-trip while
    # the PII fields mask.
    [read_back] =
      Patient
      |> Ash.Query.filter(primary_provider_id == ^staff.id)
      |> Ash.Query.ensure_selected([:full_name, :dob, :mrn, :primary_provider_id])
      |> Ash.read!()

    assert read_back.id == patient.id
    assert read_back.primary_provider_id == staff.id

    # Vault-stack fix (P0): every vault-routed PII field reads back as %Masked{},
    # the field's NORMAL value — composite AND scalar, no per-resource read hook.
    assert %Samen.Masked{} = read_back.full_name
    assert %Samen.Masked{} = read_back.dob
    assert %Samen.Masked{} = read_back.mrn

    # Vault-stack fix (P0): the domain column holds a `vt_*` TOKEN, NOT plaintext.
    # Raw SQL is the ground truth — no "MRN-9", no "Grace"/"Hopper" anywhere.
    %{rows: [[mrn_val, fname, dob_val]]} =
      TestRepo.query!(
        "SELECT pii_pat_mrn, pat_full_name, pii_pat_dob FROM pat_patient WHERE pat_id = $1",
        [Ecto.UUID.dump!(patient.id)]
      )

    for v <- [mrn_val, fname, dob_val] do
      assert String.starts_with?(v, "vt_"), "expected a vault token, got: #{inspect(v)}"
    end

    refute mrn_val == "MRN-9"
    refute fname =~ "Grace"
    refute fname =~ "Hopper"
  end
end
