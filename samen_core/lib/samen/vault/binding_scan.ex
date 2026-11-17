defmodule Samen.Vault.BindingScan do
  @moduledoc """
  Does every vault token stored in a domain table belong to the record that holds it?
  (the engine behind `mix samen.verify.vault_token_binding`; evaluation 2026-11-13,
  `spec/evaluation-2026-11-13/token-binding-design.md` §2.3).

  `Samen.Vault.Change` binds a `%Masked{}` to the record's subject and field on every governed
  write, and `Samen.Api.PiiResolution` reveals bound-only. This scan covers what those cannot
  see: rows written before the binding existed, and writes that bypassed Ash (raw SQL, a data
  migration, a restore).

  ## What it reads

  For every resource with `pii do` fields and every vault-routed column, a keyset-paged
  `LEFT JOIN pii_vault v ON v.token = d.<column>` over the cells that are not NULL. The expected
  owner of a cell is the record's primary key (the vault subject), the field's declared vault and
  its logical name — exactly what `Samen.Vault.Change` writes.

  ## Classes (one finding per cell for the first that applies, in this order)

    * `non_token_value` — the cell is not token-shaped (`Samen.Vault.token?/1`): plaintext at
      rest in a vault column (a `"vt_"`-prefixed plaintext was persisted verbatim before the type
      layer refused it).
    * `dangling_token` — token-shaped, but no `pii_vault` row.
    * `foreign_subject` — the row's subject is not this record's primary key.
    * `field_mismatch` — the row is this record's, but for another vault or field.

  and, independently of the above:

    * `shared_token` — the same token sits in more than one domain cell (across all tables and
      columns). Every holder is reported; which one is the rightful owner is a review decision.

  ## Output discipline

  A finding carries the resource, the field, the record id and the class. It NEVER carries a
  token or a value, and `format/1` prints nothing else.

  ## Report only

  Nothing is repaired here. NULLing a cell is destructive and re-minting a foreign subject's
  plaintext into this record would launder it, so remediation is a reviewed owner decision.
  """

  alias Samen.Vault

  @classes [:non_token_value, :dangling_token, :foreign_subject, :field_mismatch, :shared_token]
  @default_page 500

  @type finding :: %{
          class: atom(),
          resource: module(),
          field: atom(),
          record_id: String.t()
        }

  @doc "The finding classes, in reporting order."
  @spec classes() :: [atom()]
  def classes, do: @classes

  @doc """
  Scan `resources` through `repo`. Returns `{findings, stats}`; `stats` is
  `%{columns: n, cells: n}` (how much was actually examined, so a caller can refuse a scan that
  examined nothing).

  Options: `:page_size` (default #{@default_page}).
  """
  @spec scan(Ecto.Repo.t(), [module()], keyword()) :: {[finding()], %{columns: non_neg_integer(), cells: non_neg_integer()}}
  def scan(repo, resources, opts \\ []) do
    page = Keyword.get(opts, :page_size, @default_page)
    columns = columns(resources)

    {per_cell, cells} =
      Enum.reduce(columns, {[], 0}, fn col, {acc, n} ->
        {found, count} = scan_column(repo, col, page)
        {[found | acc], n + count}
      end)

    shared = shared_findings(repo, columns)

    findings =
      per_cell
      |> Enum.reverse()
      |> List.flatten()
      |> Kernel.++(shared)
      |> Enum.sort_by(&{inspect(&1.resource), &1.field, &1.record_id, class_rank(&1.class)})

    {findings, %{columns: length(columns), cells: cells}}
  end

  @doc "One line per finding: class, resource, field, record id. No token, no value."
  @spec format(finding()) :: String.t()
  def format(%{class: class, resource: resource, field: field, record_id: id}) do
    "#{class}: #{inspect(resource)}.#{field} record #{id}"
  end

  # ---------------------------------------------------------------------------
  # Column discovery
  # ---------------------------------------------------------------------------

  defp columns(resources) do
    for resource <- resources,
        table = Samen.Catalog.table_name(resource),
        is_binary(table),
        field <- Samen.Pii.Info.fields(resource) do
      pk = pk_attr(resource)

      %{
        resource: resource,
        table: table,
        field: field,
        pk_col: column_name(resource, pk),
        col: to_string(field.storage_name)
      }
    end
  end

  defp pk_attr(resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [pk | _] -> pk
      [] -> :id
    end
  end

  defp column_name(resource, attr_name) do
    case Ash.Resource.Info.attribute(resource, attr_name) do
      %{source: source} when not is_nil(source) -> to_string(source)
      _ -> to_string(attr_name)
    end
  end

  # ---------------------------------------------------------------------------
  # Per-cell classes
  # ---------------------------------------------------------------------------

  defp scan_column(repo, col, page), do: scan_pages(repo, col, page, nil, [], 0)

  defp scan_pages(repo, col, page, after_pk, acc, count) do
    rows = fetch_page(repo, col, page, after_pk)

    found =
      Enum.flat_map(rows, fn [_pk, pk_text, value, row_token, subject, vault, field] ->
        case classify(col, pk_text, value, row_token, subject, vault, field) do
          nil -> []
          class -> [finding(col, class, pk_text)]
        end
      end)

    acc = found ++ acc
    count = count + length(rows)

    if length(rows) < page do
      {acc, count}
    else
      [last_pk | _] = List.last(rows)
      scan_pages(repo, col, page, last_pk, acc, count)
    end
  end

  defp fetch_page(repo, col, page, after_pk) do
    base =
      "SELECT d.#{q(col.pk_col)}, d.#{q(col.pk_col)}::text, d.#{q(col.col)}::text, " <>
        "v.token, v.subject_id, v.vault_name, v.field_name " <>
        "FROM #{q(col.table)} d LEFT JOIN pii_vault v ON v.token = d.#{q(col.col)}::text " <>
        "WHERE d.#{q(col.col)} IS NOT NULL"

    {sql, params} =
      case after_pk do
        nil ->
          {base <> " ORDER BY d.#{q(col.pk_col)} LIMIT $1", [page]}

        pk ->
          {base <> " AND d.#{q(col.pk_col)} > $1 ORDER BY d.#{q(col.pk_col)} LIMIT $2", [pk, page]}
      end

    %{rows: rows} = repo.query!(sql, params)
    rows
  end

  defp classify(col, pk_text, value, row_token, subject, vault, field) do
    cond do
      not Vault.token?(value) -> :non_token_value
      is_nil(row_token) -> :dangling_token
      subject != pk_text -> :foreign_subject
      vault != to_string(col.field.vault) or field != to_string(col.field.name) -> :field_mismatch
      true -> nil
    end
  end

  defp finding(col, class, pk_text) do
    %{class: class, resource: col.resource, field: col.field.name, record_id: pk_text}
  end

  # ---------------------------------------------------------------------------
  # shared_token: the same token in more than one domain cell, across every table/column
  # ---------------------------------------------------------------------------

  defp shared_findings(_repo, []), do: []

  defp shared_findings(repo, columns) do
    union =
      columns
      |> Enum.map(fn c -> "SELECT #{q(c.col)}::text AS tok FROM #{q(c.table)} WHERE #{q(c.col)} IS NOT NULL" end)
      |> Enum.join(" UNION ALL ")

    %{rows: shared_rows} =
      repo.query!("SELECT tok FROM (#{union}) t GROUP BY tok HAVING count(*) > 1", [])

    case Enum.map(shared_rows, fn [tok] -> tok end) do
      [] ->
        []

      shared ->
        Enum.flat_map(columns, fn c ->
          %{rows: rows} =
            repo.query!(
              "SELECT d.#{q(c.pk_col)}::text FROM #{q(c.table)} d " <>
                "WHERE d.#{q(c.col)}::text = ANY($1::text[]) ORDER BY d.#{q(c.pk_col)}",
              [shared]
            )

          Enum.map(rows, fn [pk_text] -> finding(c, :shared_token, pk_text) end)
        end)
    end
  end

  defp class_rank(class), do: Enum.find_index(@classes, &(&1 == class))

  # Identifiers come from compiled resource definitions (table / source names), never from
  # data; quote them anyway so a name can only ever be an identifier.
  defp q(name), do: ~s("#{String.replace(to_string(name), "\"", "\"\"")}")
end
