defmodule Samen.Transformers.MaterializePii do
  @moduledoc """
  Turns each `pii_attribute` in a resource's `pii do … end` section into a real
  `Ash.Resource.Attribute` backed by a **vault token column** — never a plaintext
  column (Gate-0 vault-stack fix, mandatory P0 correctness).

  ## The column holds a token, not plaintext

  The logical PII attribute (`:full_name`, `:emails`, `:dob`, …) is materialized
  with type `Samen.Type.VaultField`, whose physical storage is `:string`. That
  column holds an opaque `vt_*` **token** (the FK into `pii_vault`); the plaintext
  is encrypted per-subject and lives only as ciphertext in `pii_vault`. On read
  the column's `cast_stored` presents `%Samen.Masked{}` as the field's normal
  value; on write `Samen.Vault.Change` replaces the plaintext with the token
  BEFORE it is dumped, and `Samen.Type.VaultField.dump_to_native/2` refuses to
  write anything that is not already a token (fail closed — the domain column can
  never receive plaintext).

  There is intentionally **no** separate plaintext column and **no** `_token`
  side column: the ONE domain column for the field IS the token column. This is
  the correctness reconciliation the Gate-0 audit required — the earlier T1.3/T1.4
  shape that kept `pat_full_name`/`pii_pat_dob` plaintext columns alongside token
  columns was the leak.

  ## Storage naming (vision doc §core "PII routing note")

    * **Composite** PII fields (`Samen.Type.FullName/Emails/Phones`, or anything
      `Samen.Pii.Classification` calls a composite PII type) route *by vault name*
      and carry the resource abbrev but **no** `pii_` column prefix. These get
      `source: nil`, so `Samen.Transformers.AbbrevStorage` prefixes them normally:
      `full_name` → `pat_full_name` (a `:string` token column).
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
      with {:ok, dsl_state} <-
             Enum.reduce(pii_attrs, {:ok, dsl_state}, fn
               pii_attr, {:ok, acc} -> {:ok, add_column(acc, pii_attr, abbrev)}
               _pii_attr, error -> error
             end) do
        # Wire the resource↔vault Change (Gate-0 vault-stack fix, P0 integration):
        # a global change routes each set pii_attribute plaintext to the vault on
        # create/update and replaces the domain column value with the FK token.
        # Only inject it when the resource actually declares pii_attributes.
        if pii_attrs == [] do
          {:ok, dsl_state}
        else
          add_vault_change(dsl_state)
        end
      end
    end
  end

  defp add_vault_change(dsl_state) do
    {:ok, change} = Ash.Resource.Builder.build_change(Samen.Vault.Change)
    {:ok, Transformer.add_entity(dsl_state, [:changes], change)}
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
    # The logical PII attribute is materialized as a VaultField-typed `:string`
    # column that holds a `vt_*` token — NEVER plaintext. On read it presents
    # %Masked{}; on write Samen.Vault.Change replaces the plaintext with the token
    # before dump, and VaultField.dump_to_native refuses to write non-tokens.
    attribute = %Ash.Resource.Attribute{
      name: name,
      type: Samen.Type.VaultField,
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
end
