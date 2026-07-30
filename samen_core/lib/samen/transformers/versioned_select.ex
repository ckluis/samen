defmodule Samen.Transformers.VersionedSelect do
  @moduledoc """
  Adds `Samen.Versioning.SelectForVersion` as a resource-level change to any resource that
  declared `versioned true` (ADR-040 §6) — the E7 glue that loads the write result's
  attributes so ash_paper_trail can build its diff.

  Added via a transformer (mirroring `Samen.Transformers.ImpersonationAudit`) rather than a
  `changes do … end` block in the `versioned` DSL, so it composes with a resource that
  already declares its own `changes` block (e.g. the CMS `Page`'s cascade changes) without a
  duplicate-section clash. A no-op on non-versioned resources.

  Registered `on: [:create, :update, :destroy]` — the archive of an archivable+versioned
  resource is a `:destroy`-type action that must still version (§6.4), and a hard destroy
  records its final version too.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    if Transformer.get_option(dsl_state, [:samen], :versioned, false) do
      {:ok, change} =
        Ash.Resource.Builder.build_change(Samen.Versioning.SelectForVersion,
          on: [:create, :update, :destroy]
        )

      {:ok, Transformer.add_entity(dsl_state, [:changes], change)}
    else
      {:ok, dsl_state}
    end
  end
end
