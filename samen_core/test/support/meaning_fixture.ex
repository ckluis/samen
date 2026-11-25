defmodule SamenCore.Support.MeaningFixture do
  @moduledoc """
  Shared fixture for the catalog-meaning tests (ADR-043 §8a): compiles a throwaway `Samen.Resource` from source so
  a test can prove a compile-time refusal or read a described resource back.

  A storage abbrev is permanent and hands-off (`priv/abbrev_registry.json` is only written by the sanctioned
  allocator, `mix samen.abbrev.reserve`), so a fixture cannot invent one. Instead it borrows two owners the registry
  already holds for compile-string-only fixtures, `SamenCore.PiiRedPath.BadVault` (`piv`) and
  `SamenCore.PiiRedPath.UnclassifiedNonPii` (`piu`), which `pii_red_path_test.exs` also compiles. That is safe
  because every file using them is `async: false` (ExUnit runs sync modules one at a time, after the async ones),
  and every compile here PURGES the module first and again on exit, so no two files ever hold one module at once
  and no redefinition warning is raised. This module is the ONLY place that knows the owner names.
  """

  @owners %{
    full: {SamenCore.PiiRedPath.BadVault, "piv"},
    scratch: {SamenCore.PiiRedPath.UnclassifiedNonPii, "piu"}
  }

  @doc """
  Compile `body` (resource DSL sections) as an archivable `Samen.Resource` under the `:full` or `:scratch` owner.
  Returns the module. The caller purges it on exit (`purge/1`).
  """
  @spec compile!(String.t(), :full | :scratch) :: module()
  def compile!(body, slot \\ :scratch) do
    {mod, abbrev} = Map.fetch!(@owners, slot)
    purge(mod)

    Code.compile_string("""
    defmodule #{inspect(mod)} do
      use Samen.Resource,
        otp_app: :samen_core,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: AshPostgres.DataLayer,
        abbrev: "#{abbrev}",
        archivable: true

      postgres do
        table "#{abbrev}_thing"
        repo SamenCore.TestRepo
      end

      #{body}
    end
    """)

    mod
  end

  @doc "Purge a fixture module (and its Inspect protocol impl) from the VM."
  @spec purge(module()) :: :ok
  def purge(mod) do
    for m <- [mod, Module.concat(Inspect, mod)] do
      :code.purge(m)
      :code.delete(m)
    end

    :ok
  end

  @described """
  resource do
    description "A fixture deal used to prove catalog meaning."
  end

  meaning do
    synonyms ["contract"]
    field :value, label: "Deal value", synonyms: ["amount"]
    field :count, units: "pieces"
  end

  attributes do
    attribute :value, Samen.Type.Money, public?: true, description: "Expected value of the fixture deal."
    attribute :count, :integer, public?: true, description: "How many pieces the fixture deal covers."
    attribute :status, :atom, public?: true, constraints: [one_of: [:open, :won]]
  end

  relationships do
    belongs_to :company, SamenCore.Support.Crm.Company do
      public? true
      description "The company the fixture deal is with."
    end
  end
  """

  @doc "Compile the described CRM-shaped fixture under the `:full` owner and return it."
  @spec described!() :: module()
  def described! do
    {mod, _} = Map.fetch!(@owners, :full)
    purge(mod)
    compile_described()
  end

  @doc "Purge the module `described!/0` compiled."
  @spec unload_described() :: :ok
  def unload_described do
    {mod, _} = Map.fetch!(@owners, :full)
    purge(mod)
  end

  defp compile_described, do: compile!(@described, :full)
end
