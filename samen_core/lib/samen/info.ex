defmodule Samen.Info do
  @moduledoc """
  Introspection surface for the `samen do … end` section (S0.2 note F4).

  Reads the resource's abbrev back through Spark's normal extension surface, so
  the catalog, verifiers, and LLM-grounding artifacts all query it uniformly
  rather than reaching into module attributes.
  """

  @doc """
  Returns the resource's declared abbrev as a string, or `nil` if none is set.

  Reads from the `samen` DSL section (the first-class source of truth). Prefer
  `fetch_abbrev!/1` where a missing abbrev is a hard error.
  """
  @spec abbrev(Spark.Dsl.t() | module()) :: String.t() | nil
  def abbrev(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:samen], :abbrev, nil)
  end
end
