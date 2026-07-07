defmodule Samen.Transformers.MaterializeCustomFields do
  @moduledoc """
  Wires the Tier-1 custom-field **validated-at-write** change (plan T3.8 (b))
  onto every resource that carries a `:custom` jsonb bag.

  The bag itself is an ordinary `attribute(:custom, :map)` a resource (or the
  `Samen.Fragments.CorePerson` fragment) declares — this transformer does NOT
  create it (opt-in per resource, matching the vision doc where only some scope
  resources carry `xxx_custom`). What it DOES do: when a `:custom` attribute is
  present, inject `Samen.CustomFields.Change` into the resource's `changes` so
  every write to the bag is validated against the org's `tnt_field` definitions.

  ## Opt-in, not universal (design decision, T3.8 (a))

  We inject the change only when the resource declares a `:custom` bag, rather
  than forcing a bag onto every resource. Reasons:

    * The vision doc shows `xxx_custom` on `person`/`company`-shaped records, not
      on join tables or config-row resources (a `role` config row has no need for
      a tenant bag).
    * Forcing a bag everywhere would add an uncatalogued-until-defined jsonb
      column to tables that never want one, widening the sealed jsonb zone for no
      benefit.

  So the rule is: **declare `attribute(:custom, :map)` to opt a resource into
  Tier-1 custom fields**; the base macro then wires the validation automatically.
  A resource with a bag but no validation change would be a containment hole, so
  the wiring is not left to the resource author — it is injected here whenever the
  bag exists.

  ## Ordering

  Runs after `Samen.Transformers.CoreAttributes` (which may add `org_id`, needed
  by the change to resolve the tenant boundary) and is independent of
  `AbbrevStorage` (it adds a change, not an attribute). We only read the
  attribute set, so ordering vs. AbbrevStorage does not matter — the bag's
  logical name is `:custom` regardless of its storage prefix.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @bag_attr :custom

  @impl true
  def after?(Samen.Transformers.CoreAttributes), do: true
  def after?(_), do: false

  @impl true
  def before?(_), do: false

  @impl true
  def transform(dsl_state) do
    has_bag? =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> Enum.any?(&(&1.name == @bag_attr))

    if has_bag? do
      {:ok, change} = Ash.Resource.Builder.build_change(Samen.CustomFields.Change)
      {:ok, Transformer.add_entity(dsl_state, [:changes], change)}
    else
      {:ok, dsl_state}
    end
  end
end
