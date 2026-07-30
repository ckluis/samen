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

  @doc """
  Returns whether the resource opted into the soft-delete substrate
  (`use Samen.Resource, archivable: true` / `samen do archivable true end`).

  This is the introspection surface T37's catalog-driven adoption probe (ADR-040
  §5.9) reads to assert every rostered-archivable resource carries the capability
  and every exclusion does not.
  """
  @spec archivable?(Spark.Dsl.t() | module()) :: boolean()
  def archivable?(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:samen], :archivable, false) == true
  end

  @doc """
  Returns whether the resource opted into the E7 audit-on-write substrate
  (`use Samen.Resource, versioned: true` / `samen do versioned true end`, ADR-040 §6).

  This is the introspection surface the change-log adoption probe reads to assert
  every `versioned` resource carries a generated `<Resource>.Version` and every
  non-opted resource writes none.
  """
  @spec versioned?(Spark.Dsl.t() | module()) :: boolean()
  def versioned?(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:samen], :versioned, false) == true
  end

  @doc """
  Returns the `change_tracking_mode` a `versioned` resource runs
  (`:changes_only` default, or `:snapshot`; ADR-040 §6.3(5)). Meaningful only when
  `versioned?/1` is true.
  """
  @spec versioned_mode(Spark.Dsl.t() | module()) :: :changes_only | :snapshot
  def versioned_mode(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:samen], :versioned_mode, :changes_only)
  end
end
