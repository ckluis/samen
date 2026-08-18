defmodule Samen.Transformers.ArchivableAttribute do
  @moduledoc """
  The ADR-037 §5.3 **C2(a) integration duty** for the ash_archival adoption: inject the
  `archived_at` column as an **abbrev-prefixed, select-by-default** attribute onto any
  resource that declared `archivable true` — the one thing ash_archival's own setup does
  not do the samen way.

    * `archived_at :utc_datetime_usec`, `allow_nil? true` — **NULL = live** (spec-q c6),
      the same attribute + type ash_archival's `archive` section defaults to.
    * `constraints: [precision: :microsecond]` (T124 fix — was `constraints: []`, a real
      cascade-restore correctness bug reproduced live by the T37b verifier,
      `_orch/verify/T37b-verdict.json` finding `F1-same-second-mis-restore`). Building the
      raw `%Ash.Resource.Attribute{}` directly (as this transformer does) bypasses the DSL
      constraint-default merge that `Ash.Type.UtcDatetimeUsec`'s `NewType` wrapper would
      otherwise apply, so an empty `constraints: []` silently fell through to
      `Ash.Type.Datetime`'s OWN default (`precision: :second`, `ash/lib/ash/type/
      datetime.ex`) — which makes `storage_type/1` resolve to plain `:utc_datetime` and
      `Ecto.Type.cast/2` truncate every stamped instant to whole seconds, REGARDLESS of the
      column's actual `:utc_datetime_usec` Postgres storage capacity. Composition cascades
      (`Samen.Scopes.Cms.CascadeRestore` et al., ADR-040 §5.4) key restore-matching on
      `archived_at` equality as their sole discriminator, so two independent archives
      landing in the same wall-clock second collided and a cascade restore mis-restored an
      unrelated sibling. Explicitly stating the precision here restores true microsecond
      granularity and closes the collision window (astronomically, not just practically).
    * `source: nil`, so `Samen.Transformers.AbbrevStorage` owns the prefix and the physical
      column is `<abbrev>_archived_at` (self-qualifying storage). ash_archival ships it
      `public?: false` and unprefixed; injecting ours first makes its `add_new_attribute`
      a no-op while keeping the column prefixed and readable by the trash/restore surfaces.

  ## Ordering (both are load-bearing)

    * **before `Samen.Transformers.AbbrevStorage`** — so the injected column is prefixed.
    * **before `AshArchival.Resource.Transformers.SetupArchival`** — so OUR prefixed,
      selectable attribute wins over ash_archival's own (its `add_new_attribute` skips an
      existing `archived_at`). The soft-destroy rewrite + `is_nil(archived_at)` default read
      filter still come from ash_archival's SetupArchival — not re-implemented here.

  ## Idempotence

  Additive-only: skips if the resource already declares `archived_at`. Persists
  `:samen_archivable?` for introspection.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @persist_key :samen_archivable?

  @impl true
  def before?(Samen.Transformers.AbbrevStorage), do: true
  def before?(AshArchival.Resource.Transformers.SetupArchival), do: true
  def before?(_), do: false

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    if Transformer.get_option(dsl_state, [:samen], :archivable, false) do
      dsl_state
      |> Transformer.persist(@persist_key, true)
      |> maybe_add_archived_at()
      |> then(&{:ok, &1})
    else
      {:ok, Transformer.persist(dsl_state, @persist_key, false)}
    end
  end

  @doc false
  @spec persist_key() :: atom()
  def persist_key, do: @persist_key

  defp maybe_add_archived_at(dsl_state) do
    already? =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> Enum.any?(&(&1.name == :archived_at))

    if already? do
      dsl_state
    else
      Transformer.add_entity(dsl_state, [:attributes], archived_at_attribute(), type: :append)
    end
  end

  defp archived_at_attribute do
    %Ash.Resource.Attribute{
      name: :archived_at,
      type: Ash.Type.get_type(:utc_datetime_usec),
      # source nil => AbbrevStorage owns the prefix (=> <abbrev>_archived_at).
      source: nil,
      allow_nil?: true,
      public?: true,
      writable?: true,
      # Must be selected by default: the archival read filter, idempotence guards, and
      # restore all key off `archived_at` — an unselected (NotLoaded) value would defeat
      # them. (A raw-struct injection leaves this nil, unlike the DSL default of true.)
      select_by_default?: true,
      constraints: [precision: :microsecond]
    }
  end
end
