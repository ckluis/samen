defmodule Samen.Indexing do
  @moduledoc """
  The tenant-index contract (ARCH-4): every org-scoped Ash resource carries a btree
  index `(org_id, <keyset sort>, id)` so an org-scoped keyset page never degrades to a
  sequential scan as tenants grow. One module owns the shape; the migration helper
  (`Samen.Migration.create_org_keyset_indexes/1`), the generator (`mix samen.gen.indexes`)
  and the verifier (`mix samen.verify.indexes`) all derive from it, so they cannot drift.

  ## The mechanism (why this exact shape)

  `Samen.Web.Reads.build/3` (every `*_page/3` read) emits, after the `Samen.Policy.OrgScope`
  filter `org_id = $1`:

      ORDER BY <sort> <dir>, id <dir>      -- the SAME direction on both columns
      WHERE (<sort>, id) is after the cursor  -- an OR-chain, applied as a filter
      LIMIT page_size + 1

  A btree on `(org_id, <sort>, id)` has the equality column first and then exactly the
  ORDER BY, so Postgres walks it forward for `ASC, ASC` and backward for `DESC, DESC`
  (including NULLS: a forward scan is `NULLS LAST`, a backward one `NULLS FIRST`, which are
  the defaults Ash emits for `:asc` and `:desc`) and stops after `LIMIT` rows with no sort
  node. A page sorted by `id` alone (the `ListState` default when a view names no sort) is
  served by the prefix `(org_id, id)` only when the resource declares no `keyset_sort`.

  The sort field is the resource's `samen do keyset_sort ... end` (`use Samen.Resource,
  keyset_sort: :name`) and must equal the `default_sort` of the list view that reads it
  (`samen_web`'s `Samen.Web.KeysetSortParityTest` pins that). A user who clicks another
  column header sorts by a column the index does not lead with: that page reads the org's
  rows through `(org_id, …)` and sorts them (bounded by one org, not by the table).

  ## What counts as org-scoped

  A resource with an `org_id` attribute, a Postgres table, and `Samen.Policy.OrgScope` in
  its policies (the tenant plane; the same definition as `mix samen.verify.same_org_fk`).
  A resource that carries the column but reads through another policy (`OrgIsSelf`, token
  lookups, the operator aggregate projections) is not read by an org-scoped keyset page.

  ## Fail-honest

  A resource whose policies or table cannot be inspected is reported as `{:error, reason}`,
  never silently treated as "not org-scoped".
  """

  @org_scope "OrgScope"

  @typedoc "What the contract requires of one resource."
  @type spec :: %{
          resource: module(),
          schema: String.t(),
          table: String.t(),
          name: String.t(),
          columns: [String.t()],
          logical: [atom()]
        }

  @doc """
  Classify `resource`: `:org_scoped`, `:not_org_scoped`, or `{:error, reason}` when the
  resource cannot be inspected (never a silent `:not_org_scoped`).
  """
  @spec classify(module()) :: :org_scoped | :not_org_scoped | {:error, String.t()}
  def classify(resource) do
    cond do
      not (Code.ensure_loaded?(resource) and Ash.Resource.Info.resource?(resource)) ->
        {:error, "#{inspect(resource)} is not a loadable Ash resource"}

      Ash.Resource.Info.attribute(resource, :org_id) == nil ->
        :not_org_scoped

      Ash.Resource.Info.data_layer(resource) != AshPostgres.DataLayer ->
        :not_org_scoped

      Ash.Policy.Authorizer not in Ash.Resource.Info.authorizers(resource) ->
        :not_org_scoped

      true ->
        policies_mention_org_scope(resource)
    end
  end

  defp policies_mention_org_scope(resource) do
    if resource |> Ash.Policy.Info.policies() |> Enum.any?(&(inspect(&1) =~ @org_scope)) do
      :org_scoped
    else
      :not_org_scoped
    end
  rescue
    e ->
      {:error,
       "#{inspect(resource)} policies could not be read (#{inspect(e.__struct__)}) — " <>
         "cannot tell whether it is org-scoped"}
  end

  @doc """
  The index `resource` must carry, derived from its attributes and its
  `keyset_sort` declaration. `{:error, reason}` when the declaration is unusable.
  """
  @spec spec(module()) :: {:ok, spec()} | {:error, String.t()}
  def spec(resource) do
    table = AshPostgres.DataLayer.Info.table(resource)
    sort = Samen.Info.keyset_sort(resource)

    with {:table, true} <- {:table, is_binary(table) and table != ""},
         {:ok, org} <- column(resource, :org_id),
         {:ok, id} <- column(resource, :id),
         {:ok, sort_cols} <- sort_columns(resource, sort) do
      {:ok,
       %{
         resource: resource,
         schema: AshPostgres.DataLayer.Info.schema(resource) || "public",
         table: table,
         name: "#{table}_org_keyset_idx",
         columns: [org] ++ sort_cols ++ [id],
         logical: [:org_id] ++ List.wrap(sort) ++ [:id]
       }}
    else
      {:table, false} -> {:error, "#{inspect(resource)} declares no Postgres table"}
      {:error, _} = error -> error
    end
  end

  defp sort_columns(_resource, nil), do: {:ok, []}

  defp sort_columns(resource, sort) do
    with {:ok, col} <- column(resource, sort), do: {:ok, [col]}
  end

  defp column(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil ->
        {:error,
         "#{inspect(resource)} has no attribute #{inspect(name)} (the keyset index column — " <>
           "`keyset_sort` must name a stored attribute)"}

      %{source: source} when not is_nil(source) ->
        {:ok, to_string(source)}

      %{name: attr} ->
        {:ok, to_string(attr)}
    end
  end

  @doc """
  Every org-scoped resource across `domains`, plus the resources that could not be
  classified: `{org_scoped, errors}`.
  """
  @spec org_scoped([module()]) :: {[module()], [{module(), String.t()}]}
  def org_scoped(domains) do
    domains
    |> Enum.flat_map(&Ash.Domain.Info.resources/1)
    |> Enum.uniq()
    |> Enum.reduce({[], []}, fn resource, {ok, err} ->
      case classify(resource) do
        :org_scoped -> {[resource | ok], err}
        :not_org_scoped -> {ok, err}
        {:error, reason} -> {ok, [{resource, reason} | err]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)
  end

  # ---------------------------------------------------------------------------
  # The live catalog
  # ---------------------------------------------------------------------------

  @index_sql """
  SELECT ic.relname::text,
         i.indisvalid,
         i.indisready,
         i.indpred IS NOT NULL,
         am.amname::text,
         ARRAY(SELECT CASE WHEN k.n = 0 THEN NULL ELSE a.attname::text END
                 FROM unnest(i.indkey::int2[]) WITH ORDINALITY AS k(n, ord)
                 LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.n
                WHERE k.ord <= i.indnkeyatts
                ORDER BY k.ord),
         ARRAY(SELECT (o.v & 1) = 1
                 FROM unnest(string_to_array(i.indoption::text, ' ')::int2[]) WITH ORDINALITY AS o(v, ord)
                WHERE o.ord <= i.indnkeyatts
                ORDER BY o.ord)
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_am am ON am.oid = ic.relam
   WHERE i.indrelid = to_regclass($1)
  """

  @doc """
  The indexes the live database declares on `schema.table`, as maps
  `%{name, valid, ready, partial, method, keys, desc}` (`keys` holds `nil` for an
  expression column; `desc` is per key column). `{:error, reason}` when the table is absent
  or the catalog cannot be read.
  """
  @spec live_indexes(module(), String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def live_indexes(repo, schema, table) do
    qualified = ~s("#{schema}"."#{table}")

    with {:ok, %{rows: [[found]]}} <- repo.query("SELECT to_regclass($1)::text", [qualified]),
         true <- found != nil,
         {:ok, %{rows: rows}} <- repo.query(@index_sql, [qualified]) do
      {:ok,
       Enum.map(rows, fn [name, valid, ready, partial, method, keys, desc] ->
         %{name: name, valid: valid, ready: ready, partial: partial, method: method, keys: keys, desc: desc}
       end)}
    else
      false -> {:error, "table #{qualified} does not exist in the live database"}
      {:error, e} -> {:error, "catalog query failed: #{Exception.message(e)}"}
      other -> {:error, "unexpected catalog answer #{inspect(other)}"}
    end
  rescue
    e -> {:error, "catalog query raised #{inspect(e.__struct__)}: #{Exception.message(e)}"}
  end

  @doc """
  Does `index` serve `spec`? A plain, valid, ready, non-partial btree whose leading key
  columns are exactly `spec.columns` (extra trailing columns are fine), with the sort and
  `id` columns in ONE direction (the helpers order both the same way, and a backward scan
  serves the all-descending case).
  """
  @spec serves?(map(), spec()) :: boolean()
  def serves?(index, %{columns: columns}) do
    n = length(columns)

    index.valid and index.ready and not index.partial and index.method == "btree" and
      Enum.take(index.keys, n) == columns and length(index.keys) >= n and
        same_direction?(Enum.take(index.desc, n))
  end

  # org_id is an equality column, so its own direction is irrelevant; the ORDER BY columns
  # after it must agree.
  defp same_direction?([_org | order]), do: Enum.uniq(order) |> length() <= 1
end
