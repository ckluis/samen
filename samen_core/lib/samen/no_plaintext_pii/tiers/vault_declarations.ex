defmodule Samen.NoPlaintextPii.Tiers.VaultDeclarations do
  @moduledoc """
  CI-mode tier (a): **every vault-routed declaration's storage column holds
  tokens/ciphertext, never a plaintext PII type** (T1.8d clause (a); doc §data
  token-only-downstream).

  For every `pii_attribute` declared in a `pii do … end` block, this tier asserts:

    1. The DOMAIN column (the materialized attribute's storage) is typed
       `Samen.Type.VaultField` — the token type whose `dump_to_native/2` refuses
       to persist anything but a `vt_*` token and whose `cast_stored/2` presents
       `%Masked{}`. If the materialized attribute type is anything else (a raw
       `:string`, a plaintext composite like `Samen.Type.FullName`), the domain
       column could hold plaintext — a leak. This is the exact Gate-0 vault-stack
       shape: the domain column IS the token column, never an alongside-plaintext
       column.

    2. The physical DB column exists and is `character varying` / `text` (a token
       string column), not a structured plaintext type.

  This is a DECLARATION-keyed check (doc C3/C5): it keys on `Samen.Pii.Info`
  introspection over the `pii do` block, never on a `pii_` column-name prefix (a
  composite field like `pat_full_name` carries no prefix but IS vault-routed).
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.Finding
  alias Samen.Pii.Info, as: PiiInfo

  @tier :vault_declarations

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do: "every vault-routed pii_attribute column is the VaultField token type (never plaintext)"

  @impl true
  def check(context) do
    Enum.flat_map(context.resources, fn resource ->
      check_resource(resource, context)
    end)
  end

  # ---------------------------------------------------------------------------

  defp check_resource(resource, context) do
    table = table_name(resource)

    if is_nil(table) do
      []
    else
      resource
      |> PiiInfo.pii_attributes()
      |> Enum.flat_map(fn attr -> check_attribute(resource, table, attr, context) end)
    end
  end

  defp check_attribute(resource, table, attr, context) do
    materialized = materialized_type(resource, attr.name)
    storage_name = storage_name(resource, attr.name)
    subject = "#{table}.#{storage_name}"

    cond do
      # The materialized (post-transformer) type MUST be the token type. If it is
      # not, the domain column is not guaranteed to hold a token — fail closed.
      materialized != Samen.Type.VaultField ->
        [
          Finding.violation(
            @tier,
            subject,
            "vault-routed declaration :#{attr.name} materialized to #{inspect(materialized)}, " <>
              "not Samen.Type.VaultField — the domain column is not a token column and could " <>
              "hold plaintext PII. (The MaterializePii transformer must retype every " <>
              "pii_attribute to the VaultField token type.)"
          )
        ]

      # The physical column must exist and be a string/text token column.
      true ->
        check_physical_column(table, storage_name, subject, context)
    end
  end

  defp check_physical_column(table, column, subject, context) do
    case column_udt(context.repo, table, column) do
      {:ok, udt} ->
        if udt in ["varchar", "text", "bpchar"] do
          []
        else
          [
            Finding.violation(
              @tier,
              subject,
              "vault-routed column has physical type #{inspect(udt)}, expected a token " <>
                "string column (varchar/text). A non-string physical type means the column " <>
                "is not holding an opaque vt_* token."
            )
          ]
        end

      :not_found ->
        [
          Finding.violation(
            @tier,
            subject,
            "vault-routed column is declared but MISSING from the physical schema — " <>
              "cannot assert it is a token column (fail closed)."
          )
        ]

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            subject,
            "could not introspect the physical column (#{inspect(reason)}) — fail closed."
          )
        ]
    end
  end

  # The materialized attribute type is what the MaterializePii transformer set as
  # the attribute's type. For a vault-routed field this must be Samen.Type.VaultField.
  defp materialized_type(resource, name) do
    resource
    |> Ash.Resource.Info.attribute(name)
    |> case do
      %{type: type} -> type
      _ -> nil
    end
  end

  defp storage_name(resource, name) do
    resource
    |> Ash.Resource.Info.attribute(name)
    |> case do
      %{source: source} when not is_nil(source) -> to_string(source)
      %{name: n} -> to_string(n)
      _ -> to_string(name)
    end
  end

  defp column_udt(nil, _table, _column), do: {:error, :no_repo}

  defp column_udt(repo, table, column) do
    %{rows: rows} =
      repo.query!(
        "SELECT udt_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2",
        [table, column]
      )

    case rows do
      [[udt] | _] -> {:ok, udt}
      [] -> :not_found
    end
  rescue
    e -> {:error, e}
  end

  defp table_name(resource) do
    AshPostgres.DataLayer.Info.table(resource)
  rescue
    _ -> nil
  end
end
