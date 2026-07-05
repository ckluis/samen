defmodule Samen.Transformers.AbbrevStorage do
  @moduledoc """
  Compile-time Spark transformer implementing Samen's *self-qualifying storage*
  idiom. Reused verbatim from S0.2/S0.4.

  Given a resource declared with `use Samen.Resource, abbrev: "com"`, every
  attribute's physical storage name (the Ash `:source`) is rewritten to
  `"<abbrev>_<name>"`. App code keeps addressing attributes by logical name; the
  DB column / migration / catalog entry all carry the abbrev.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def after?(Ash.Resource.Transformers.BelongsToAttribute), do: true
  def after?(_), do: false

  @impl true
  def before?(Ash.Resource.Transformers.BelongsToAttribute), do: false
  def before?(_), do: true

  @impl true
  def transform(dsl_state) do
    abbrev = Samen.Resource.fetch_abbrev!(dsl_state)

    new_dsl =
      dsl_state
      |> Transformer.persist(:samen_abbrev, abbrev)
      |> prefix_attributes(abbrev)

    {:ok, new_dsl}
  end

  defp prefix_attributes(dsl_state, abbrev) do
    dsl_state
    |> Transformer.get_entities([:attributes])
    |> Enum.reduce(dsl_state, fn attribute, acc ->
      Transformer.replace_entity(
        acc,
        [:attributes],
        prefix_attribute(attribute, abbrev),
        fn candidate -> candidate.name == attribute.name end
      )
    end)
  end

  defp prefix_attribute(%{source: source, name: name} = attribute, abbrev)
       when source in [nil, name] do
    %{attribute | source: prefixed(abbrev, name)}
  end

  defp prefix_attribute(attribute, _abbrev), do: attribute

  defp prefixed(abbrev, name), do: :"#{abbrev}_#{name}"
end
