defmodule Samen.Transformers.MaterializePii do
  @moduledoc """
  Turns each `pii_attribute` in a resource's `pii do … end` section into a real
  `Ash.Resource.Attribute` so it gets a physical column — with the storage name
  the vision doc's PII routing note mandates.

  ## Storage naming (vision doc §core "PII routing note")

    * **Composite** PII fields (`Samen.Type.FullName/Emails/Phones`, or anything
      `Samen.Pii.Classification` calls a composite PII type) route *by vault name*
      and carry the resource abbrev but **no** `pii_` column prefix. These get
      `source: nil`, so `Samen.Transformers.AbbrevStorage` prefixes them normally:
      `full_name` → `pat_full_name`.
    * **Scalar** `pii_attribute` fields carry the `pii_` prefix. This transformer
      sets an explicit `source: :pii_<abbrev>_<name>` (e.g. `pii_pat_dob`,
      `pii_drv_cdl_number`). `AbbrevStorage` honors an explicit non-logical
      `:source` verbatim (S0.2 note F2), so it does NOT double-prefix.

  Both are equally vault-routed — the distinction is purely the physical column
  name. Downstream verifiers key on the `pii do` / vault **declaration**
  (see `Samen.Pii.Info`), never on the presence/absence of the `pii_` prefix.

  ## Ordering

  Runs BEFORE `Samen.Transformers.AbbrevStorage`. For composite fields that means
  AbbrevStorage owns the prefix; for scalar fields this transformer has already
  set the fully-qualified `source`, which AbbrevStorage leaves untouched.

  ## Scope note (T1.3)

  This still *materializes* the field as a plain (`sensitive?: true`) column. The
  vault split (`pii_*` table + ciphertext + FK token, `%Masked{}` as the field's
  normal value) is T1.4/T1.5, which replaces the materialization with token
  routing — but keys on the SAME `Samen.Pii.Info` declarations this transformer
  respects, so the storage names are stable across that transition.
  """
  use Spark.Dsl.Transformer

  alias Samen.Pii.Classification
  alias Spark.Dsl.Transformer

  @impl true
  def before?(Samen.Transformers.AbbrevStorage), do: true
  def before?(_), do: false

  @impl true
  def after?(_), do: false

  @impl true
  def transform(dsl_state) do
    abbrev = Samen.Resource.fetch_abbrev!(dsl_state)
    pii_attrs = Enum.filter(Transformer.get_entities(dsl_state, [:pii]), &match?(%Samen.Pii.Attribute{}, &1))

    # RED PATH, fail-closed (T1.3): a pii_attribute may only route to a vault
    # declared with `vault :name` in the SAME (folded) pii block. We enforce this
    # HERE, at the transformer stage, not only in the VaultDeclared verifier —
    # because a Spark *verifier* DslError does not reliably abort compile in this
    # Ash/Spark version (T1.1 documented the same for the abbrev registry), whereas
    # a transformer returning {:error, DslError} DOES hard-fail the build. The
    # verifier remains as defense-in-depth + introspection.
    with :ok <- verify_vaults_declared(dsl_state, pii_attrs) do
      Enum.reduce(pii_attrs, {:ok, dsl_state}, fn
        pii_attr, {:ok, acc} -> {:ok, add_column(acc, pii_attr, abbrev)}
        _pii_attr, error -> error
      end)
    end
  end

  defp verify_vaults_declared(dsl_state, pii_attrs) do
    declared =
      dsl_state
      |> Transformer.get_entities([:pii])
      |> Enum.filter(&match?(%Samen.Pii.Vault{}, &1))
      |> Enum.map(& &1.name)
      |> MapSet.new()

    case Enum.find(pii_attrs, fn a -> not MapSet.member?(declared, a.vault) end) do
      nil ->
        :ok

      %Samen.Pii.Attribute{name: name, vault: vault} ->
        module = Transformer.get_persisted(dsl_state, :module)

        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:pii, :pii_attribute, name],
           message:
             "pii_attribute #{inspect(name)} routes to vault #{inspect(vault)}, which " <>
               "is not declared. Declare it with `vault #{inspect(vault)}` in the " <>
               "`pii do` block (closed-world routing: a pii_attribute cannot point at " <>
               "a non-existent / typo'd vault). Declared vaults: " <>
               "#{inspect(MapSet.to_list(declared))}."
         )}
    end
  end

  defp add_column(dsl_state, %Samen.Pii.Attribute{name: name} = pii_attr, abbrev) do
    attribute = %Ash.Resource.Attribute{
      name: name,
      type: Ash.Type.get_type(storage_type(pii_attr)),
      source: source_for(pii_attr, abbrev),
      allow_nil?: true,
      public?: true,
      writable?: true,
      sensitive?: true,
      constraints: []
    }

    Transformer.add_entity(dsl_state, [:attributes], attribute, type: :append)
  end

  # Composite PII types route by vault name → NO pii_ prefix → let AbbrevStorage
  # prefix normally (source: nil). Scalar PII fields carry the pii_ prefix, set
  # here as an explicit fully-qualified source that AbbrevStorage will honor.
  defp source_for(%Samen.Pii.Attribute{name: name, type: type}, abbrev) do
    if composite_pii?(type) do
      nil
    else
      :"pii_#{abbrev}_#{name}"
    end
  end

  # A composite PII field is one whose declared type is a PII type with a :map /
  # composite storage shape (FullName/Emails/Phones, or a host custom PII type).
  # Scalar PII fields (:string, :date, :integer under pii_attribute) get the
  # pii_ prefix.
  defp composite_pii?(type) do
    module = resolve(type)
    Classification.classify(module) == :pii and composite_storage?(module)
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

  # storage_type for the materialized column. Explicit override wins; then the
  # composite/scalar type; scalars fall through to their native Ash type.
  defp storage_type(%Samen.Pii.Attribute{storage_type: t}) when is_atom(t) and not is_nil(t),
    do: t

  defp storage_type(%Samen.Pii.Attribute{type: type}) do
    module = resolve(type)

    cond do
      composite_storage?(module) -> :map
      is_atom(type) and type in [:string, :date, :integer, :boolean, :uuid] -> type
      # unknown/custom scalar → store as string materialization (T1.4 vaults it).
      true -> :string
    end
  end
end
