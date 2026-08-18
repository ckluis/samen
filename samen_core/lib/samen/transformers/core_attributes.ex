defmodule Samen.Transformers.CoreAttributes do
  @moduledoc """
  Injects the universal Samen columns onto every resource:

    * `id`          — `uuid_primary_key` (binary_id), if the resource has no PK yet
    * `org_id`      — the tenant scope FK column (uuid), if not already declared
    * `inserted_at` — creation timestamp (`create_timestamp`)
    * `updated_at`  — last-write timestamp (`update_timestamp`)

  Every Samen object lives in one of the seven universal scopes and is org-scoped
  and auditable, so these four are non-negotiable. Declaring them here (rather than
  making every resource repeat them) is the "one base macro" promise from the doc's
  §runs core block.

  ## Idempotence

  The transformer is additive-only: it skips any of the four that the resource
  already declares (e.g. a fixture that wrote its own `uuid_primary_key :id` or a
  scope like Identity.Org that legitimately has no `org_id`). This lets a resource
  opt a column out simply by declaring it itself, and keeps composition with
  fragments (which may contribute a PK) safe.

  ## Ordering

  Runs BEFORE `Samen.Transformers.AbbrevStorage` so the injected columns are
  prefixed (`com_id`, `com_org_id`, `com_inserted_at`, `com_updated_at`) exactly
  like hand-declared ones. It also runs after `BelongsToAttribute` is irrelevant
  here — these are plain attributes, not relationships.
  """
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @impl true
  def before?(Samen.Transformers.AbbrevStorage), do: true
  def before?(_), do: false

  # Injected timestamps are ordinary attributes; no relationship interaction.
  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    existing =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> MapSet.new(& &1.name)

    has_pk? =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> Enum.any?(& &1.primary_key?)

    dsl_state
    |> maybe_add_id(existing, has_pk?)
    |> maybe_add(existing, :org_id, &org_id_attribute/0)
    |> maybe_add(existing, :inserted_at, &inserted_at_attribute/0)
    |> maybe_add(existing, :updated_at, &updated_at_attribute/0)
    |> then(&{:ok, &1})
  end

  # Only inject a primary key if the resource declared none at all. If it has ANY
  # primary key (even a non-`id` one), we do not force `id` on it.
  defp maybe_add_id(dsl_state, existing, has_pk?) do
    if has_pk? or MapSet.member?(existing, :id) do
      dsl_state
    else
      add_attribute(dsl_state, id_attribute())
    end
  end

  defp maybe_add(dsl_state, existing, name, builder) do
    if MapSet.member?(existing, name) do
      dsl_state
    else
      add_attribute(dsl_state, builder.())
    end
  end

  defp add_attribute(dsl_state, attribute) do
    Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
  end

  defp id_attribute do
    %Ash.Resource.Attribute{
      name: :id,
      type: Ash.Type.get_type(:uuid),
      # source nil => AbbrevStorage owns the prefix (=> com_id).
      source: nil,
      allow_nil?: false,
      primary_key?: true,
      writable?: false,
      public?: true,
      default: &Ash.UUID.generate/0,
      generated?: false,
      constraints: []
    }
  end

  defp org_id_attribute do
    %Ash.Resource.Attribute{
      name: :org_id,
      type: Ash.Type.get_type(:uuid),
      source: nil,
      allow_nil?: false,
      public?: true,
      writable?: true,
      # Explicit booleans (each == the Ash default, so no behaviour change): a raw-struct
      # injection leaves these `nil`, which the E7 version-resource generator rejects when
      # it mirrors org_id onto the `<Resource>.Version` via ash_paper_trail's
      # `attributes_as_attributes` (ADR-040 §6.2) — it re-declares the attribute through the
      # DSL, which validates each option as a boolean. Filling them lets the copy succeed;
      # org_id keeps its default query/write posture.
      always_select?: false,
      primary_key?: false,
      generated?: false,
      sensitive?: false,
      constraints: []
    }
  end

  # Second-precision "now" matching the :utc_datetime storage column.
  @doc false
  def now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp inserted_at_attribute do
    %Ash.Resource.Attribute{
      name: :inserted_at,
      type: Ash.Type.get_type(:utc_datetime),
      source: nil,
      allow_nil?: false,
      writable?: false,
      public?: true,
      default: &__MODULE__.now/0,
      match_other_defaults?: true,
      constraints: []
    }
  end

  defp updated_at_attribute do
    %Ash.Resource.Attribute{
      name: :updated_at,
      type: Ash.Type.get_type(:utc_datetime),
      source: nil,
      allow_nil?: false,
      writable?: false,
      public?: true,
      default: &__MODULE__.now/0,
      update_default: &__MODULE__.now/0,
      match_other_defaults?: true,
      constraints: []
    }
  end
end
