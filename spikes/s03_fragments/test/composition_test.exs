defmodule Samen.CompositionTest do
  @moduledoc """
  S0.3 acceptance suite: fragment single-table composition.

  Proves:
    * each composed resource = ONE physical table (`pat_patient`, `stf_staff`);
    * the fragment (`Core.Person`) has NO table (it is not a resource);
    * fragment attributes inherit the *composing* resource's abbrev prefix
      (same fragment → `pat_*` on Patient, `stf_*` on Staff);
    * `belongs_to :primary_provider, Staff` from Patient targets the Staff TABLE
      (a real FK, `references(:stf_staff, column: :stf_id)`);
    * the generated DDL contains NO `INHERITS` anywhere.

  The RED PATH (a fragment declaring an extension the resource lacks fails to
  compile) lives in `red_path_test.exs`.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Resource.Info
  alias Clinical.Patient
  alias Clinical.Staff
  alias S03Fragments.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  defp domain_migration_path do
    Path.wildcard(
      Path.join([__DIR__, "..", "priv", "repo", "migrations", "*_initial_spike*.exs"])
    )
    |> Enum.reject(&String.contains?(&1, "extensions"))
    |> List.first()
  end

  defp migration_ddl, do: File.read!(domain_migration_path())

  # ==========================================================================
  # ONE physical table per composed resource; fragment has NO table
  # ==========================================================================

  test "each composed resource maps to exactly ONE physical table" do
    assert AshPostgres.DataLayer.Info.table(Patient) == "pat_patient"
    assert AshPostgres.DataLayer.Info.table(Staff) == "stf_staff"
  end

  test "the migration creates exactly two tables — one per composed resource" do
    ddl = migration_ddl()

    tables = Regex.scan(~r/create table\(:(\w+)/, ddl) |> Enum.map(&List.last/1)
    assert Enum.sort(tables) == ["pat_patient", "stf_staff"]

    # There is no fragment table. Core.Person is a fragment, not a resource, so
    # no table bears its (non-existent) abbrev.
    refute ddl =~ ~r/create table\(:(person|cor|core)_?/
  end

  test "the fragment Core.Person is NOT a resource and has no data layer / table" do
    # A fragment does not implement the Ash resource introspection surface.
    refute Ash.Resource.Info.resource?(Core.Person)
    # It is a Spark fragment (exposes extensions/0 from Spark.Dsl.Fragment).
    assert function_exported?(Core.Person, :extensions, 0)
    assert Samen.Pii in Core.Person.extensions()
    assert Samen.Catalog in Core.Person.extensions()
  end

  # ==========================================================================
  # Fragment attributes inherit the COMPOSING resource's abbrev prefix
  # ==========================================================================

  test "fragment (shared) attributes inherit the composing resource's abbrev" do
    pat = Map.new(Info.attributes(Patient), &{&1.name, &1.source})
    stf = Map.new(Info.attributes(Staff), &{&1.name, &1.source})

    # Same fragment attribute, two different prefixes — proof the fragment has no
    # abbrev of its own; it inherits the composer's.
    assert pat[:job_title] == :pat_job_title
    assert stf[:job_title] == :stf_job_title
    assert pat[:custom] == :pat_custom
    assert stf[:custom] == :stf_custom
  end

  test "fragment PII-section attributes also inherit the composing abbrev" do
    pat = Map.new(Info.attributes(Patient), &{&1.name, &1.source})
    stf = Map.new(Info.attributes(Staff), &{&1.name, &1.source})

    for field <- [:full_name, :emails, :phones] do
      assert pat[field] == :"pat_#{field}", "expected pat_#{field}, got #{inspect(pat[field])}"
      assert stf[field] == :"stf_#{field}", "expected stf_#{field}, got #{inspect(stf[field])}"
    end
  end

  test "resource's OWN pii_attribute declarations are prefixed too" do
    pat = Map.new(Info.attributes(Patient), &{&1.name, &1.source})
    # dob/mrn declared in Patient's own `pii do` block.
    assert pat[:dob] == :pat_dob
    assert pat[:mrn] == :pat_mrn
  end

  test "logical names are unchanged — app code addresses :full_name, not :pat_full_name" do
    names = Enum.map(Info.attributes(Patient), & &1.name)
    assert :full_name in names
    assert :job_title in names
    refute :pat_full_name in names
    refute :pat_job_title in names
  end

  # ==========================================================================
  # belongs_to targets the composed STAFF TABLE (real FK), never the fragment
  # ==========================================================================

  test "belongs_to :primary_provider resolves to the Staff resource (a real table)" do
    rel = Info.relationship(Patient, :primary_provider)
    assert rel.destination == Staff
    # Never the fragment.
    refute rel.destination == Core.Person
  end

  test "the FK column references the Staff TABLE and its prefixed PK" do
    ddl = migration_ddl()

    # FK attribute itself is prefixed with Patient's abbrev.
    assert ddl =~ "add(\n        :pat_primary_provider_id" or ddl =~ "add(:pat_primary_provider_id"
    # It references the real Staff table + prefixed PK.
    assert ddl =~ "references(:stf_staff"
    assert ddl =~ "column: :stf_id"
  end

  # ==========================================================================
  # NO Postgres table inheritance anywhere (the whole safety story)
  # ==========================================================================

  test "generated DDL contains NO `INHERITS` anywhere" do
    ddl_files =
      Path.wildcard(Path.join([__DIR__, "..", "priv", "repo", "migrations", "*.exs"]))

    assert ddl_files != []

    for f <- ddl_files do
      contents = File.read!(f)
      refute contents =~ ~r/inherits/i, "INHERITS found in #{f}"
    end
  end

  test "the LIVE database schema uses no table inheritance (pg_inherits is empty)" do
    # Definitive check: query Postgres itself. Fragment composition compiles to
    # single tables, so there must be zero inheritance relationships.
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM pg_inherits", [])
    assert count == 0

    # And both composed tables physically exist as ordinary base tables.
    %{rows: rows} =
      Repo.query!(
        "SELECT relname, relkind, relhassubclass FROM pg_class WHERE relname = ANY($1)",
        [["pat_patient", "stf_staff"]]
      )

    by_name = Map.new(rows, fn [name, kind, hassub] -> {name, {kind, hassub}} end)
    # relkind 'r' = ordinary table; relhassubclass false = no children (no INHERITS parent).
    assert by_name["pat_patient"] == {"r", false}
    assert by_name["stf_staff"] == {"r", false}
  end

  # ==========================================================================
  # End-to-end: composition produces working, queryable resources over ONE table
  # ==========================================================================

  test "create + FK + read work across the two composed tables" do
    org_id = Ash.UUID.generate()

    staff =
      Staff
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        license_no: "MD-123",
        full_name: "Dr. Ada",
        job_title: "Physician"
      })
      |> Ash.create!()

    patient =
      Patient
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        full_name: "Grace Hopper",
        job_title: "patient",
        dob: ~D[1906-12-09],
        mrn: "MRN-9",
        primary_provider_id: staff.id
      })
      |> Ash.create!()

    # PII-materialized fields are sensitive?: true, so the create result leaves
    # them NotLoaded by default (fail-closed by omission — the S0.5 masking story
    # lives here in miniature). The non-PII FK is returned normally.
    assert patient.primary_provider_id == staff.id

    # Read them back explicitly to prove the round-trip through the single table.
    [read_back] =
      Patient
      |> Ash.Query.filter(mrn == "MRN-9")
      |> Ash.Query.ensure_selected([:full_name, :dob, :primary_provider_id])
      |> Ash.read!()

    assert read_back.id == patient.id
    assert read_back.full_name == "Grace Hopper"
    assert read_back.dob == ~D[1906-12-09]
    assert read_back.primary_provider_id == staff.id
  end
end
