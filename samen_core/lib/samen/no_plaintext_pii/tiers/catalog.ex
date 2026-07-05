defmodule Samen.NoPlaintextPii.Tiers.Catalog do
  @moduledoc """
  CI-mode tier (b): **the catalog itself exposes only catalogued metadata, and
  every vault-routed column's catalog `fld_field` type is the token type, never a
  plaintext PII type** (T1.8d clause (b); doc §"A catalog for machines").

  Two assertions:

    1. **Catalog-of-vault-columns type parity.** For every vault-routed storage
       column (from `Samen.Pii.Info`), the `fld_field.fld_type` recorded for that
       `(table, column)` must be the token type (`"VaultField"`) — NOT a plaintext
       PII type string like `"String"`/`"Date"`/`"FullName"`. The catalog is the
       machine-readable projection of the schema; if it advertises a vault column
       as a plaintext type, either the transformer didn't retype it (tier (a)
       would also catch it) or the catalog drifted — both are leaks of the
       token-only invariant AT THE CATALOG SURFACE.

    2. **Catalog storage tables carry only metadata.** The `tam_table` / `fld_field`
       rows themselves must not contain subject PII. Their columns are fixed
       metadata (`fld_table_name`, `fld_column_name`, `fld_logical_name`,
       `fld_type`, ids) — this tier asserts no plaintext-PII-named column has been
       added to the catalog storage tables.

  A vault column with NO catalog row is a `catalog_parity` (C1) concern, not this
  tier's — this tier only asserts the TYPE of the rows that exist. It reports a
  missing row as an informational note routed to C1, not a violation here, to keep
  the tiers single-purpose (fail-closed coverage is C1's job for that case).
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.PiiClassify

  @tier :catalog

  @catalog_tables ~w(tam_table fld_field)
  @plaintext_udts ~w(varchar text bpchar date)

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :ci

  @impl true
  def describe,
    do: "catalog advertises vault columns as the token type; catalog tables carry only metadata"

  @impl true
  def check(%Context{repo: nil}) do
    [
      Finding.violation(
        @tier,
        "<repo>",
        "no repo configured — cannot read fld_field (fail closed)."
      )
    ]
  end

  def check(%Context{} = context) do
    catalog_type_findings(context) ++ catalog_table_findings(context)
  end

  # ---------------------------------------------------------------------------
  # (1) vault column ⇒ fld_field.fld_type must be the token type
  # ---------------------------------------------------------------------------

  defp catalog_type_findings(context) do
    case fld_types(context.repo) do
      {:ok, type_by_col} ->
        context.vault_routed
        |> Enum.flat_map(fn {table, column} ->
          case Map.get(type_by_col, {table, column}) do
            nil ->
              # No catalog row — C1 (catalog_parity) owns that. Not a type leak.
              []

            fld_type ->
              if token_type?(fld_type) do
                []
              else
                [
                  Finding.violation(
                    @tier,
                    "#{table}.#{column}",
                    "catalog fld_field advertises this vault-routed column as fld_type " <>
                      "#{inspect(fld_type)}, not the token type \"VaultField\". The catalog is " <>
                      "the machine-readable schema projection; advertising a vault column as a " <>
                      "plaintext PII type breaks the token-only invariant at the catalog surface."
                  )
                ]
              end
          end
        end)

      {:error, reason} ->
        [Finding.violation(@tier, "fld_field", "could not read fld_field (#{inspect(reason)}) — fail closed.")]
    end
  end

  defp token_type?(fld_type) do
    fld_type in ["VaultField", "Samen.Type.VaultField"]
  end

  # ---------------------------------------------------------------------------
  # (2) catalog storage tables carry only metadata
  # ---------------------------------------------------------------------------

  defp catalog_table_findings(context) do
    Enum.flat_map(@catalog_tables, fn table ->
      case columns(context.repo, table) do
        {:ok, cols} ->
          Enum.flat_map(cols, fn {name, udt} ->
            if udt in @plaintext_udts and PiiClassify.pii_name?(strip_prefix(name)) do
              [
                Finding.violation(
                  @tier,
                  "#{table}.#{name}",
                  "a PII-named plaintext (#{udt}) column on a catalog storage table. The " <>
                    "machine catalog must carry only schema metadata, never subject PII."
                )
              ]
            else
              []
            end
          end)

        {:error, reason} ->
          [Finding.violation(@tier, table, "could not introspect (#{inspect(reason)}) — fail closed.")]
      end
    end)
  end

  # ---------------------------------------------------------------------------

  defp strip_prefix(name) do
    case String.split(name, "_", parts: 2) do
      [abbrev, rest] when byte_size(abbrev) == 3 -> rest
      _ -> name
    end
  end

  defp fld_types(repo) do
    %{rows: rows} =
      repo.query!("SELECT fld_table_name, fld_column_name, fld_type FROM fld_field")

    {:ok, Map.new(rows, fn [t, c, ty] -> {{t, c}, ty} end)}
  rescue
    e -> {:error, e}
  end

  defp columns(repo, table) do
    %{rows: rows} =
      repo.query!(
        "SELECT column_name, udt_name FROM information_schema.columns " <>
          "WHERE table_schema = 'public' AND table_name = $1 ORDER BY column_name",
        [table]
      )

    {:ok, Enum.map(rows, fn [c, u] -> {c, u} end)}
  rescue
    e -> {:error, e}
  end
end
