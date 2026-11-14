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
  served by `(org_id, id)`, which is the index of a resource that declares no `keyset_sort`;
  a resource WITH a `keyset_sort` has no index for an id-only page (it sorts the org's rows).

  ## The index name carries the sort column

  `<table>_org_<sort>_id_idx` (`<table>_org_id_idx` when there is no `keyset_sort`). The name
  is the identity of the SHAPE: change a resource's `keyset_sort` and the contract names a
  different index, so `mix samen.verify.indexes` goes red against a database still holding the
  old one, and `mix samen.gen.indexes` writes a migration that builds the new one (a
  same-named `IF NOT EXISTS` would silently skip). The migrations the generator writes spell
  table, columns and name as LITERALS, so an applied migration never changes meaning when the
  code later does. The old index is dropped by a follow-up (contract-phase) migration.

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

  `opts[:keyset_sorts]` (a `%{resource => sort}` map; tests only) replaces the DECLARED sort
  of the resources it names — the way a test asks "what would the contract require if this
  resource's `keyset_sort` changed", without needing a second compiled resource.
  """
  @spec spec(module(), keyword()) :: {:ok, spec()} | {:error, String.t()}
  def spec(resource, opts \\ []) do
    table = AshPostgres.DataLayer.Info.table(resource)

    sort =
      case Map.fetch(Keyword.get(opts, :keyset_sorts, %{}), resource) do
        {:ok, override} -> override
        :error -> Samen.Info.keyset_sort(resource)
      end

    with {:table, true} <- {:table, is_binary(table) and table != ""},
         {:ok, org} <- column(resource, :org_id),
         {:ok, id} <- column(resource, :id),
         {:ok, sort_cols} <- sort_columns(resource, sort),
         {:ok, name} <- index_name(resource, table, sort) do
      {:ok,
       %{
         resource: resource,
         schema: AshPostgres.DataLayer.Info.schema(resource) || "public",
         table: table,
         name: name,
         columns: [org] ++ sort_cols ++ [id],
         logical: [:org_id] ++ List.wrap(sort) ++ [:id]
       }}
    else
      {:table, false} -> {:error, "#{inspect(resource)} declares no Postgres table"}
      {:error, _} = error -> error
    end
  end

  # Postgres silently truncates an identifier at 63 bytes, which would make two shapes share a
  # name — refuse instead of truncating.
  @max_name_bytes 63

  defp index_name(resource, table, sort) do
    name = "#{table}_org_#{if sort, do: "#{sort}_"}id_idx"

    if byte_size(name) <= @max_name_bytes do
      {:ok, name}
    else
      {:error,
       "#{inspect(resource)}: the index name #{name} is #{byte_size(name)} bytes; Postgres allows " <>
         "#{@max_name_bytes} (it would truncate it and two shapes could share a name) — " <>
         "shorten the table name or the keyset_sort attribute name"}
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
                ORDER BY o.ord),
         ARRAY(SELECT (o.v & 2) = 2
                 FROM unnest(string_to_array(i.indoption::text, ' ')::int2[]) WITH ORDINALITY AS o(v, ord)
                WHERE o.ord <= i.indnkeyatts
                ORDER BY o.ord),
         ARRAY(SELECT coalesce(a.attcollation = c.v, true)
                 FROM unnest(string_to_array(i.indcollation::text, ' ')::oid[]) WITH ORDINALITY AS c(v, ord)
                 LEFT JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[c.ord - 1]
                WHERE c.ord <= i.indnkeyatts
                ORDER BY c.ord),
         ARRAY(SELECT coalesce(oc.opcdefault, false)
                 FROM unnest(string_to_array(i.indclass::text, ' ')::oid[]) WITH ORDINALITY AS k(v, ord)
                 LEFT JOIN pg_opclass oc ON oc.oid = k.v
                WHERE k.ord <= i.indnkeyatts
                ORDER BY k.ord)
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_am am ON am.oid = ic.relam
   WHERE i.indrelid = to_regclass($1)
  """

  @doc """
  The indexes the live database declares on `schema.table`, as maps
  `%{name, valid, ready, partial, method, keys, desc, nulls_first, default_collation,
  default_opclass}` (`keys` holds `nil` for an expression column; the rest are per key column:
  `desc` / `nulls_first` are the `indoption` bits, `default_collation` is "the index key uses
  the column's own collation", `default_opclass` is "the key uses the type's default btree
  operator class"). `{:error, reason}` when the table is absent
  or the catalog cannot be read.
  """
  @spec live_indexes(module(), String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def live_indexes(repo, schema, table) do
    qualified = ~s("#{schema}"."#{table}")

    with {:ok, %{rows: [[found]]}} <- repo.query("SELECT to_regclass($1)::text", [qualified]),
         true <- found != nil,
         {:ok, %{rows: rows}} <- repo.query(@index_sql, [qualified]) do
      {:ok,
       Enum.map(rows, fn [name, valid, ready, partial, method, keys, desc, nulls_first, default_collation, default_opclass] ->
         %{
           name: name,
           valid: valid,
           ready: ready,
           partial: partial,
           method: method,
           keys: keys,
           desc: desc,
           nulls_first: nulls_first,
           default_collation: default_collation,
           default_opclass: default_opclass
         }
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
  serves the all-descending case), with the NULLS ordering Ash emits for that direction
  (`NULLS LAST` ascending, `NULLS FIRST` descending — a different bit cannot deliver the
  ORDER BY), the column's own collation and the type's default operator class (a `text_pattern_ops`
  or other-collation key orders differently from the `ORDER BY` the page sends).
  """
  @spec serves?(map(), spec()) :: boolean()
  def serves?(index, %{columns: columns}) do
    n = length(columns)

    index.valid and index.ready and not index.partial and index.method == "btree" and
      length(index.keys) >= n and Enum.take(index.keys, n) == columns and
      same_direction?(Enum.take(index.desc, n)) and
      default_nulls?(Enum.take(index.desc, n), Enum.take(index.nulls_first, n)) and
      Enum.all?(Enum.take(index.default_collation, n)) and
      Enum.all?(Enum.take(index.default_opclass, n))
  end

  # org_id is an equality column, so its own direction is irrelevant; the ORDER BY columns
  # after it must agree.
  defp same_direction?([_org | order]), do: Enum.uniq(order) |> length() <= 1

  # Ash emits `NULLS LAST` for :asc and `NULLS FIRST` for :desc (the Postgres defaults), so an
  # ORDER BY column serves only when its index NULLS bit equals its DESC bit.
  defp default_nulls?([_org | desc], [_org_nulls | nulls_first]), do: desc == nulls_first

  @doc """
  The indexes of `indexes` that look like a keyset index of ANOTHER shape for `spec`: led by
  the same `org_id` column, running on to the `id` column, but neither named like the contract's
  index nor serving it. These are what a changed `keyset_sort` leaves behind; the verifier names
  them so the operator can drop them in a follow-up migration once the new index is built.
  """
  @spec superseded([map()], spec()) :: [map()]
  def superseded(indexes, %{columns: [org | _] = columns, name: name} = spec) do
    id = List.last(columns)

    Enum.filter(indexes, fn index ->
      index.name != name and index.method == "btree" and Enum.at(index.keys, 0) == org and
        length(index.keys) >= 2 and id in index.keys and
        not serves?(index, spec)
    end)
  end
end
