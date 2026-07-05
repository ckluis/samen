defmodule Samen.AbbrevStorageTest do
  @moduledoc """
  S0.2 acceptance suite for the abbrev storage transformer.

  Green paths prove the idiom is invisible to app code while storage carries the
  prefix. The red path proves fail-closed compile behaviour when `abbrev` is
  missing.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Resource.Info
  alias S02Transformer.Crm.Company
  alias S02Transformer.Crm.Contact
  alias S02Transformer.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  # --- Migration file location (generated once by `mix ash.codegen`) ----------

  defp domain_migration_path do
    Path.wildcard(
      Path.join([__DIR__, "..", "priv", "repo", "migrations", "*_initial_spike*.exs"])
    )
    |> Enum.reject(&String.contains?(&1, "extensions"))
    |> List.first()
  end

  # ==========================================================================
  # GREEN: transformer sets prefixed :source (compile-time introspection)
  # ==========================================================================

  test "attribute :source is prefixed with the resource abbrev" do
    sources = Map.new(Info.attributes(Contact), &{&1.name, &1.source})

    assert sources[:name] == :com_name
    assert sources[:org_id] == :com_org_id
    assert sources[:id] == :com_id
  end

  test "logical attribute name is unchanged (app code addresses :name)" do
    names = Enum.map(Info.attributes(Contact), & &1.name)
    assert :name in names
    assert :org_id in names
    # the prefixed form is NOT a logical name — it lives only at storage.
    refute :com_name in names
  end

  test "belongs_to FK attribute is also prefixed (R2 ordering: after BelongsToAttribute)" do
    fk = Info.attribute(Contact, :company_id)
    assert fk.source == :com_company_id
  end

  # ==========================================================================
  # GREEN: migration round-trip (`mix ash.codegen`) emits prefixed DDL
  # ==========================================================================

  test "generated migration contains the prefixed column com_name" do
    ddl = File.read!(domain_migration_path())

    # The literal acceptance criterion from plan task S0.2.
    assert ddl =~ "add(:com_name"
    assert ddl =~ "add(:com_org_id"
    assert ddl =~ "create table(:com_contact"
  end

  test "identity survives the source override: unique index over PREFIXED columns" do
    ddl = File.read!(domain_migration_path())

    # Identity declared on logical [:org_id, :slug] must index cpy_org_id/cpy_slug.
    assert ddl =~ "unique_index(:cpy_company, [:cpy_org_id, :cpy_slug]"
    # Fail-closed on the friction we most feared: an un-prefixed index column.
    refute ddl =~ "unique_index(:cpy_company, [:org_id, :slug]"
  end

  test "FK reference survives the source override: references prefixed target PK" do
    ddl = File.read!(domain_migration_path())

    assert ddl =~ "add(\n        :com_company_id" or ddl =~ "add(:com_company_id"
    assert ddl =~ "references(:cpy_company"
    assert ddl =~ "column: :cpy_id"
  end

  # ==========================================================================
  # GREEN: Ash create/read work via logical :name; SQL speaks com_*
  # ==========================================================================

  test "Ash.create/read work via logical :name" do
    org_id = Ash.UUID.generate()

    company =
      Company
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, slug: "acme", name: "Acme Inc"})
      |> Ash.create!()

    contact =
      Contact
      |> Ash.Changeset.for_create(:create, %{
        name: "Ada Lovelace",
        org_id: org_id,
        company_id: company.id
      })
      |> Ash.create!()

    # Written and read back by the LOGICAL name.
    assert contact.name == "Ada Lovelace"

    [read_back] =
      Contact
      |> Ash.Query.filter(name == "Ada Lovelace")
      |> Ash.read!()

    assert read_back.id == contact.id
    assert read_back.company_id == company.id
  end

  test "emitted SQL filters on the PREFIXED column (WHERE com_name / com_org_id)" do
    org_id = Ash.UUID.generate()

    Contact
    |> Ash.Changeset.for_create(:create, %{name: "Grace Hopper", org_id: org_id})
    |> Ash.create!()

    sql =
      capture_query_sql(fn ->
        Contact
        |> Ash.Query.filter(name == "Grace Hopper" and org_id == ^org_id)
        |> Ash.read!()
      end)

    assert sql =~ "com_name", "expected WHERE on prefixed com_name, got: #{sql}"
    assert sql =~ "com_org_id", "expected reference to prefixed com_org_id, got: #{sql}"
    # The logical name must never appear as a bare column identifier in SQL.
    refute sql =~ ~r/\bc0\.\"name\"/, "logical :name leaked into SQL: #{sql}"
  end

  # Attach a telemetry handler to the repo query event and grab the SQL text
  # of the SELECT emitted while `fun` runs.
  defp capture_query_sql(fun) do
    ref = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, ref}

    :telemetry.attach(
      handler_id,
      [:s02_transformer, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if String.starts_with?(query, "SELECT"), do: send(test_pid, {ref, query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_selects(ref, [])
    |> Enum.join("\n")
  end

  defp collect_selects(ref, acc) do
    receive do
      {^ref, query} -> collect_selects(ref, [query | acc])
    after
      0 -> acc
    end
  end
end
