defmodule Samen.Pii.Info do
  @moduledoc """
  Introspection surface for the `pii do … end` section (T1.3).

  This is the API the T1.4 vault runtime and the C3 `pii_reads` / C5
  `no_plaintext_pii` verifiers consume. It answers, for a resource:

    * which attributes are **vault-routed** (declared in a `pii do` block);
    * which **vault** each routes to;
    * each field's physical **storage name** (composite ⇒ `<abbrev>_<name>`,
      scalar ⇒ `pii_<abbrev>_<name>`).

  Verifiers key on the **declaration**, not the column name — so this module is
  the single source of truth for "is this field vault-routed?", regardless of
  whether its storage name happens to carry a `pii_` prefix.
  """

  alias Spark.Dsl.Extension

  defmodule Field do
    @moduledoc """
    A resolved vault-routed field: its logical name, declared type, vault, storage
    name, and whether it is a composite-typed field (routes by vault name, no
    `pii_` prefix) or a scalar field (carries the `pii_` prefix).
    """
    @enforce_keys [:name, :type, :vault, :storage_name, :composite?]
    defstruct [:name, :type, :vault, :storage_name, :composite?]

    @type t :: %__MODULE__{
            name: atom(),
            type: term(),
            vault: atom(),
            storage_name: atom(),
            composite?: boolean()
          }
  end

  @doc """
  All `pii_attribute` entities declared for a resource (raw DSL entities).
  """
  @spec pii_attributes(Spark.Dsl.t() | module()) :: [Samen.Pii.Attribute.t()]
  def pii_attributes(resource) do
    resource
    |> Extension.get_entities([:pii])
    |> Enum.filter(&match?(%Samen.Pii.Attribute{}, &1))
  end

  @doc """
  All declared vault names for a resource (from `vault :name` entities).
  """
  @spec vaults(Spark.Dsl.t() | module()) :: [atom()]
  def vaults(resource) do
    resource
    |> Extension.get_entities([:pii])
    |> Enum.filter(&match?(%Samen.Pii.Vault{}, &1))
    |> Enum.map(& &1.name)
  end

  @doc """
  The resolved vault-routed `Field`s for a resource — the primary API for the
  vault runtime and verifiers. Each carries the logical name, declared type,
  vault, resolved storage name, and composite? flag.

  Storage name is resolved from the *materialized* attribute's `:source` (the
  abbrev transformer's output), so it is exactly the physical column name in
  Postgres — the same value `Samen.Catalog.fields/1` records.
  """
  @spec fields(Spark.Dsl.t() | module()) :: [Field.t()]
  def fields(resource) do
    source_by_name =
      resource
      |> Ash.Resource.Info.attributes()
      |> Map.new(fn attr -> {attr.name, attr.source || attr.name} end)

    Enum.map(pii_attributes(resource), fn %Samen.Pii.Attribute{} = attr ->
      %Field{
        name: attr.name,
        type: attr.type,
        vault: attr.vault,
        storage_name: Map.get(source_by_name, attr.name, attr.name),
        composite?: composite?(attr.type)
      }
    end)
  end

  @doc """
  Map of `vault_name => [storage_name, ...]` for a resource — the routing table
  the T1.4 vault runtime uses to associate physical columns with vault tables.
  """
  @spec routing(Spark.Dsl.t() | module()) :: %{atom() => [atom()]}
  def routing(resource) do
    resource
    |> fields()
    |> Enum.group_by(& &1.vault, & &1.storage_name)
  end

  @doc """
  Is the logical field `name` on `resource` a vault-routed PII field? Keys on the
  DECLARATION, never on the storage-name prefix (a composite field like
  `per_full_name` has no `pii_` prefix but IS vault-routed).
  """
  @spec vault_routed?(Spark.Dsl.t() | module(), atom()) :: boolean()
  def vault_routed?(resource, name) do
    Enum.any?(pii_attributes(resource), &(&1.name == name))
  end

  @doc """
  The set of physical storage column names that are vault-routed for a resource —
  what C5 `no_plaintext_pii` scans across tiers, and what C3 `pii_reads` treats as
  tainted sources.
  """
  @spec vault_routed_columns(Spark.Dsl.t() | module()) :: [atom()]
  def vault_routed_columns(resource) do
    resource |> fields() |> Enum.map(& &1.storage_name)
  end

  @doc """
  The set of **reveal actions** declared for a resource via `reveal :action` in
  its `pii do … end` block (T1.5 clause (c); Gate-0 fix task #6).

  This is real introspection: it reads the persisted marker set
  (`Samen.Transformers.RevealActions`), NOT the action *name*. The C3 `pii_reads`
  verifier (T1.8b) keys reveal-scope suppression on THIS, so a laundering
  `def reveal_report/1` cannot masquerade as a reveal boundary — only a declared
  `reveal :name` action is one.

  Returns a `MapSet` of action-name atoms. Empty for a resource that declares no
  reveal actions (default deny: nothing is a reveal action unless declared).
  """
  @spec reveal_actions(Spark.Dsl.t() | module()) :: MapSet.t(atom())
  def reveal_actions(resource) do
    resource
    |> persisted(Samen.Transformers.RevealActions.persist_key())
    |> case do
      %MapSet{} = set ->
        set

      _ ->
        # Fallback for DSL-state contexts where persistence isn't materialized:
        # read the declarations directly. Same source of truth (the `reveal`
        # entity), never the action name.
        resource
        |> Extension.get_entities([:pii])
        |> Enum.filter(&match?(%Samen.Pii.RevealAction{}, &1))
        |> Enum.map(& &1.name)
        |> MapSet.new()
    end
  end

  @doc """
  Is `action_name` a declared reveal action on `resource`? Keys on the DECLARATION
  (`reveal :name`), never on the action name matching a `reveal` prefix.
  """
  @spec reveal_action?(Spark.Dsl.t() | module(), atom()) :: boolean()
  def reveal_action?(resource, action_name) do
    MapSet.member?(reveal_actions(resource), action_name)
  end

  # Reads a persisted value from either a compiled module or a raw DSL state.
  # Spark.Dsl.Extension.get_persisted/3 handles a compiled module atom directly
  # (extension.ex line 296) and a %Spark.Dsl{}/map DSL state.
  defp persisted(resource, key) do
    Spark.Dsl.Extension.get_persisted(resource, key, nil)
  rescue
    _ -> nil
  end

  defp composite?(type) do
    module = resolve(type)

    Samen.Pii.Classification.classify(module) == :pii and
      composite_storage?(module)
  end

  defp composite_storage?(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_compiled(module),
         true <- function_exported?(module, :storage_type, 1) do
      module.storage_type([]) in [:map, :array, {:array, :map}]
    else
      _ -> false
    end
  end

  defp composite_storage?(_), do: false

  defp resolve(type) when is_atom(type) do
    try do
      Ash.Type.get_type(type)
    rescue
      _ -> type
    end
  end

  defp resolve(type), do: type
end
