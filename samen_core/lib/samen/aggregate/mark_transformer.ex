defmodule Samen.Aggregate.MarkTransformer do
  @moduledoc """
  Persists the `aggregate_plane: true` marker on a resource that carries
  `Samen.Aggregate.Extension` (i.e. one declared with `use Samen.Aggregate.Resource`).

  The marker is read by `Samen.Aggregate.Info.aggregate_plane?/1` — used by the
  whole-app `mix samen.verify.no_pii_columns` backstop and the aggregate domain.

  It runs unconditionally for any resource that includes the aggregate extension:
  the presence of the extension IS the opt-in, so the marker is always true here.
  """
  use Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    {:ok, Spark.Dsl.Transformer.persist(dsl_state, Samen.Aggregate.Info.persist_key(), true)}
  end
end
