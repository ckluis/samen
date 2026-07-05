defmodule Samen.Transformers.AbbrevStorage do
  @moduledoc """
  Compile-time Spark transformer implementing Samen's *self-qualifying storage*
  idiom.

  Given a resource declared with `use Samen.Resource, abbrev: "com"`, every
  attribute's physical storage name (the Ash `:source`, which AshPostgres uses
  as the DB column name, and which every generated migration, CDC row, log line,
  and catalog entry inherits) is rewritten to `"<abbrev>_<name>"`.

  App code, actions, filters, and the public API continue to address the
  attribute by its idiomatic logical `:name` (`:name`, `:org_id`, ...). Only the
  data-layer `:source` changes, so `Ash.read/2` and `Ash.create/2` speak `:name`
  while the emitted SQL and migrations speak `com_name`.

  ## Fail-closed contract

  If the resource does not declare an `abbrev`, this transformer raises a
  `Spark.Error.DslError` at compile time with a clear diagnostic. A Samen
  resource with no abbrev cannot compile — self-qualifying storage is not
  optional (RED PATH for S0.2).

  ## Explicit-source escape hatch

  If a user set `:source` explicitly on an attribute, it is honored verbatim
  (never double-prefixed). This is what lets FK/reference attributes and any
  hand-tuned column keep a chosen storage name.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @doc false
  # Ordering is the crux of the abbrev idiom (R2 friction, documented in REPORT).
  #
  # We must run:
  #   * AFTER Ash.Resource.Transformers.BelongsToAttribute, because it *creates*
  #     the FK attribute (`company_id`) — if we run before it, the FK column is
  #     never prefixed and lands as `company_id` instead of `com_company_id`.
  #   * BEFORE everything else, especially the transformers that snapshot
  #     `attribute.source` (primary-key cache, identity/reference resolution,
  #     and AshPostgres' migration/reference logic). Those must observe the
  #     already-prefixed sources.
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

  # The DSL entity transform (`Ash.Resource.Attribute.transform/1`) defaults
  # `source` to `name` when the user did not set one. We can't tell "user set it
  # to == name" from "defaulted", so the rule is:
  #
  #   * source is nil OR source == name  -> Samen owns it -> prefix
  #   * source is something else          -> user chose it -> honor verbatim
  #
  # This keeps the idiom invisible while still letting an explicit `source:`
  # override (e.g. a legacy column) survive.
  defp prefix_attribute(%{source: source, name: name} = attribute, abbrev)
       when source in [nil, name] do
    %{attribute | source: prefixed(abbrev, name)}
  end

  defp prefix_attribute(attribute, _abbrev), do: attribute

  defp prefixed(abbrev, name), do: :"#{abbrev}_#{name}"
end
