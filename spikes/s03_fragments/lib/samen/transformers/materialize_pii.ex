defmodule Samen.Transformers.MaterializePii do
  @moduledoc """
  Turns each `pii_attribute` in a resource's `pii do … end` section into a real
  `Ash.Resource.Attribute` so it gets a physical column.

  This is the S0.3-scoped stand-in for the full S0.5 vault: instead of splitting
  the value into a `pii_*` vault table + token FK, we simply give the field a
  plain column. What S0.3 must prove is only that the `pii` section *crosses the
  fragment boundary* and that the resulting columns *inherit the composing
  resource's abbrev prefix*. So:

    * it runs BEFORE `Samen.Transformers.AbbrevStorage`, which then prefixes the
      newly-materialized columns with the composing resource's abbrev, exactly
      like any hand-declared attribute;
    * a fragment `pii_attribute :full_name` folded into Patient (`abbrev: "pat"`)
      becomes column `pat_full_name`; folded into Staff (`abbrev: "stf"`) it
      becomes `stf_full_name`. The fragment itself has no abbrev and no table.

  Fail-closed: if the `pii` section is present it must have been legally declared,
  which requires the resource to carry the `Samen.Pii` extension. A fragment that
  declares `extensions: [Samen.Pii]` but is folded into a resource that does NOT
  carry `Samen.Pii` is rejected at compile time by
  `Samen.Resource.verify_fragment_extensions!/2` (the S0.3 RED PATH).
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Must run before AbbrevStorage so the abbrev transformer sees (and prefixes)
  # the materialized columns.
  @impl true
  def before?(Samen.Transformers.AbbrevStorage), do: true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:pii])
    |> Enum.reduce({:ok, dsl_state}, fn
      pii_attr, {:ok, acc} -> {:ok, add_column(acc, pii_attr)}
      _pii_attr, error -> error
    end)
  end

  defp add_column(dsl_state, %Samen.Pii.Attribute{name: name} = pii_attr) do
    attribute = %Ash.Resource.Attribute{
      name: name,
      type: Ash.Type.get_type(storage_type(pii_attr)),
      # source left nil so AbbrevStorage owns the prefix (source == nil => prefix).
      source: nil,
      allow_nil?: true,
      public?: true,
      writable?: true,
      sensitive?: true,
      constraints: []
    }

    Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
  end

  # The spike stub stores every pii_attribute as a plain column. The doc's real
  # composite types (Samen.Type.FullName/Emails/Phones) are S0.5 territory; here
  # they collapse to :string so we can prove prefix inheritance without pulling
  # in the vault. A caller may override with `storage_type: :date` etc.
  defp storage_type(%Samen.Pii.Attribute{storage_type: t}) when is_atom(t) and not is_nil(t),
    do: t

  defp storage_type(%Samen.Pii.Attribute{type: :date}), do: :date
  defp storage_type(%Samen.Pii.Attribute{type: :string}), do: :string
  defp storage_type(_), do: :string
end
