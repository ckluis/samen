defmodule Samen.Transformers.OrgIdPinned do
  @moduledoc """
  Adds `Samen.Policy.OrgIdPinned` as a global create+update change to EVERY resource that has an
  `org_id` attribute, so the tenant column is immutable after create and an actor's create is
  bound to the actor's own org by construction. See that module for the rule.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(Samen.Transformers.CoreAttributes), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    has_org_id? =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> Enum.any?(&(&1.name == :org_id))

    if has_org_id? do
      {:ok, change} =
        Ash.Resource.Builder.build_change(Samen.Policy.OrgIdPinned, on: [:create, :update])

      {:ok, Transformer.add_entity(dsl_state, [:changes], change)}
    else
      {:ok, dsl_state}
    end
  end
end
