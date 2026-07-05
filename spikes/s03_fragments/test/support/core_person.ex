defmodule Core.Person do
  @moduledoc """
  The SHARED base fragment (doc §core `Core.Person` block).

  A `Spark.Dsl.Fragment` of `Ash.Resource` — a tableless bundle of shared
  attributes and PII routing, with NO data layer and NO table of its own. It
  declares the extensions whose DSL it uses (`Samen.Pii` for the `pii do` block,
  `Samen.Catalog` as a marker). It is folded into a composed resource via
  `use Samen.Resource, base: Core.Person`; the fragment's attributes and PII
  columns become columns of that resource, prefixed with the resource's abbrev.
  """
  use Spark.Dsl.Fragment,
    of: Ash.Resource,
    extensions: [Samen.Pii, Samen.Catalog]

  attributes do
    attribute :job_title, :string, public?: true
    attribute :custom, :map, public?: true
  end

  pii do
    pii_attribute :full_name, :string, vault: :pii_name
    pii_attribute :emails, :string, vault: :pii_email
    pii_attribute :phones, :string, vault: :pii_phone
  end
end
