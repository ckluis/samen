defmodule Samen.Transformers.AbbrevStorage do
  @moduledoc """
  Compile-time Spark transformer implementing Samen's *self-qualifying storage*
  idiom. Copied verbatim from the S0.2 spike (`spikes/s02_transformer`) — S0.3
  reuses the S0.2 transformer approach unchanged; the fragment-composition proof
  is layered on top of it.

  Given a resource declared with `use Samen.Resource, abbrev: "pat"`, every
  attribute's physical storage name (the Ash `:source`, which AshPostgres uses
  as the DB column name, and which every generated migration, CDC row, log line,
  and catalog entry inherits) is rewritten to `"<abbrev>_<name>"`.

  Crucially for S0.3: attributes *folded in from a fragment* (`base: Core.Person`)
  are ordinary attributes on the composed resource by the time this transformer
  runs, so they inherit the *composing* resource's abbrev — a fragment attribute
  named `:full_name` becomes `pat_full_name` on Patient and `stf_full_name` on
  Staff. The fragment has no abbrev of its own.

  ## Fail-closed contract

  If the resource does not declare an `abbrev`, this transformer raises a
  `Spark.Error.DslError` at compile time. Self-qualifying storage is not optional.

  ## Explicit-source escape hatch

  If a user set `:source` explicitly on an attribute, it is honored verbatim
  (never double-prefixed). This lets a hand-tuned column keep a chosen name.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  # Ordering is the crux of the abbrev idiom (R2 friction, documented in S0.2).
  # Run AFTER BelongsToAttribute (which *creates* the FK attribute) so the FK
  # column is prefixed, and BEFORE everything that snapshots `attribute.source`.
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

  #   * source is nil OR source == name  -> Samen owns it -> prefix
  #   * source is something else          -> user chose it -> honor verbatim
  defp prefix_attribute(%{source: source, name: name} = attribute, abbrev)
       when source in [nil, name] do
    %{attribute | source: prefixed(abbrev, name)}
  end

  defp prefix_attribute(attribute, _abbrev), do: attribute

  defp prefixed(abbrev, name), do: :"#{abbrev}_#{name}"
end
