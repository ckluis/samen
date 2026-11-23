defmodule Mix.Tasks.Samen.Gen.ApiKeyDigestUnique do
  @shortdoc "Write the retrofit migration that makes every API-key token digest unique."

  @moduledoc """
  `mix samen.gen.api_key_digest_unique` — the retrofit for an app generated BEFORE the API-key token digest was
  unique. The auth lookup (`token_digest == ^digest`) assumes one row per digest; the unique index used to be absent,
  and the template change sits inside the app's FIRST migration, which an existing app has already run. Run it inside
  the app, then `mix ecto.migrate`.

  It writes ONE migration, `<ts>_api_key_digest_unique.exs`, built with `concurrent_unique_index/3`
  (`Samen.Migration.ExpandContract`): `CREATE UNIQUE INDEX CONCURRENTLY` per table, outside the DDL transaction, so a
  populated table takes no write lock. It first counts values that already appear more than once and, if there are
  any, RAISES naming the table and column; it deletes nothing and prints no digest. Resolve the duplicates, run it
  again. The table, column and index name (`<table>_token_digest_uidx`) are LITERAL: an applied migration never
  changes meaning.

  Which tables: every resource of the app's `:ash_domains` whose table ends in `_api_key` and that has a
  `*_token_digest` attribute (`--domain`, repeatable, replaces the domains), plus any `--key table:column` (repeatable;
  when given, ONLY these are used, nothing is discovered). A table that already has the unique index in the app's
  migrations (this task's output, or the current `mix samen.gen.app` first migration) is skipped; when nothing is left it
  writes nothing and says so, so a re-run is harmless. A new run writes a new file whose module name carries its
  timestamp.

  A freshly generated app does not need this: its first migration creates the unique index.

  The same engine writes the CSAT survey-token retrofit: see `mix samen.gen.csat_token_digest_unique`
  (`run_kind/2`, `kind: :csat`).

  ## Usage

      mix samen.gen.api_key_digest_unique [--out path] [--timestamp 20261120100000] [--domain MyApp.Identity …] [--key table:column …]
  """
  use Mix.Task

  @typedoc "Which credential-digest table family a run covers: API keys, or the CSAT survey tokens."
  @type kind :: :api_key | :csat

  @kinds %{
    api_key: %{
      task: "samen.gen.api_key_digest_unique",
      file: "api_key_digest_unique",
      module: "ApiKeyDigestUnique",
      suffix: "_api_key",
      noun: "API-key",
      lookup: "the auth lookup (`token_digest == ^digest`)",
      effect: "a duplicate makes it error (a 503: fail-closed, but an availability hole)",
      plain_index: nil
    },
    csat: %{
      task: "samen.gen.csat_token_digest_unique",
      file: "csat_token_digest_unique",
      module: "CsatTokenDigestUnique",
      suffix: "_csat_survey_token",
      noun: "CSAT survey-token",
      lookup: "the survey lookup (`preview` reads `token_digest == ^digest` with `limit(1)`; `respond` consumes by digest)",
      effect: "a duplicate would make `preview` read an arbitrary one of the rows and `respond` consume every matching row yet answer for only one",
      plain_index: "digest_idx"
    }
  }

  @impl Mix.Task
  def run(argv), do: run_kind(argv, :api_key)

  @doc false
  @spec run_kind([String.t()], kind()) :: Path.t() | nil
  def run_kind(argv, kind) do
    k = Map.fetch!(@kinds, kind)

    {opts, _rest, _} =
      OptionParser.parse(argv, strict: [out: :string, timestamp: :string, domain: :keep, key: :keep])

    Mix.Task.run("app.config")
    Mix.Task.run("compile")

    otp_app = Mix.Project.config()[:app]
    repo = host_repo(otp_app, k)
    out_dir = Keyword.get(opts, :out) || Ecto.Migrator.migrations_path(repo)
    timestamp = Keyword.get(opts, :timestamp) || Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

    keys =
      case Keyword.get_values(opts, :key) do
        [] -> discover(domains(otp_app, Keyword.get_values(opts, :domain)), kind)
        pairs -> Enum.map(pairs, &parse_key!(&1, k))
      end

    if keys == [], do: Mix.raise("mix #{k.task}: no #{k.noun} table found; pass --key table:column")

    generate(repo, keys, out_dir, timestamp, kind)
  end

  @doc """
  Write the migration for `keys` (`[{table, column}]`) into `out_dir`, skipping tables whose unique index already
  exists there. Returns the path, or `nil` when there was nothing to write.
  """
  @spec generate(module(), [{String.t(), String.t()}], Path.t(), String.t(), kind()) :: Path.t() | nil
  def generate(repo, keys, out_dir, timestamp, kind \\ :api_key) do
    k = Map.fetch!(@kinds, kind)
    existing = existing_sources(out_dir)
    {done, todo} = Enum.split_with(Enum.sort(Enum.uniq(keys)), fn {t, c} -> present?(existing, t, c) end)

    for {t, c} <- done,
        do: Mix.shell().info("#{k.task}: #{t}.#{c} already has a unique index in the migrations; skipped")

    if todo == [] do
      Mix.shell().info("#{k.task}: nothing to do")
      nil
    else
      path = Path.join(out_dir, "#{timestamp}_#{k.file}.exs")
      File.mkdir_p!(out_dir)
      File.write!(path, render(repo, todo, timestamp, kind))
      Mix.shell().info("#{k.task}: wrote #{path} (#{length(todo)} table(s))")
      path
    end
  end

  @doc "The migration source for `keys` on `repo` at `timestamp` (pure)."
  @spec render(module(), [{String.t(), String.t()}], String.t(), kind()) :: String.t()
  def render(repo, keys, timestamp, kind \\ :api_key) do
    k = Map.fetch!(@kinds, kind)
    ups = Enum.map_join(keys, "\n", fn {t, c} -> "    concurrent_unique_index(:#{t}, :#{c}, name: \"#{index_name(t)}\")" <> drop_plain_up(k, t) end)
    downs = Enum.map_join(keys, "\n", fn {t, c} -> restore_plain_down(k, t, c) <> "    execute(\"DROP INDEX CONCURRENTLY IF EXISTS #{index_name(t)}\")" end)
    cols = Enum.map_join(keys, ", ", fn {t, c} -> "`#{t}.#{c}`" end)

    """
    defmodule #{inspect(repo)}.Migrations.#{k.module}#{timestamp} do
      @moduledoc \"\"\"
      #{k.noun} digest uniqueness — #{k.lookup} assumes one row per digest, and #{k.effect}. The invariant belongs in the
      database: #{cols}. Generated by `mix #{k.task}`.

      Table, column and index name are LITERAL: this migration means the same thing forever. Built `CONCURRENTLY`
      (no write lock on a populated table, hence `@disable_ddl_transaction true`; an index is not a catalogued
      object, so no `catalog_sync`); a same-named INVALID leftover is dropped before the build. If a table already
      holds a duplicate digest the migration RAISES, naming the table and column; it deletes nothing and prints no
      digest, so a person resolves the duplicates and runs it again.
      \"\"\"
      use Samen.Migration, phase: :expand
      @disable_ddl_transaction true
      @disable_migration_lock true

      def up do
    #{ups}
      end

      def down do
    #{downs}
      end
    end
    """
  end

  defp index_name(table), do: "#{table}_token_digest_uidx"

  # A CSAT survey table's first migration made a plain digest index (`<table>_digest_idx`); the unique index serves
  # the same lookup, so it is dropped once the unique one is built and rebuilt (first) by `down`.
  defp drop_plain_up(%{plain_index: nil}, _table), do: ""

  defp drop_plain_up(%{plain_index: suffix}, table),
    do: "\n    execute(\"DROP INDEX CONCURRENTLY IF EXISTS #{table}_#{suffix}\")"

  defp restore_plain_down(%{plain_index: nil}, _table, _column), do: ""

  defp restore_plain_down(%{plain_index: suffix}, table, column),
    do: "    concurrent_index(:#{table}, [:#{column}], name: \"#{table}_#{suffix}\")\n"

  defp existing_sources(dir) do
    dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.map(&File.read!/1)
  end

  # this task's index name, or the first migration's `create(unique_index(:table, [:col]))` (default name)
  defp present?(sources, table, column) do
    named = ~s|"#{index_name(table)}"|
    plain = ~r/unique_index\(\s*:#{Regex.escape(table)}\s*,\s*\[\s*:#{Regex.escape(column)}\s*\]/
    Enum.any?(sources, &(String.contains?(&1, named) or Regex.match?(plain, &1)))
  end

  defp parse_key!(pair, k) do
    case String.split(pair, ":") do
      [table, column] when table != "" and column != "" -> {table, column}
      _ -> Mix.raise("mix #{k.task}: --key expects table:column, got #{inspect(pair)}")
    end
  end

  defp domains(otp_app, []), do: Application.get_env(otp_app, :ash_domains, [])
  defp domains(_otp_app, names), do: Enum.map(names, &Module.concat([&1]))

  @doc """
  The `{table, digest_column}` of every resource of `kind` (default: API keys) in `domains`. The column is the STORED
  one (`Samen.Catalog.fields/1`'s `column_name`: the abbrev-prefixed `:source`, e.g. `aqt_token_digest`), never the
  logical attribute name (`:token_digest`): the emitted migration must name the column that exists in the database.
  """
  @spec discover([module()], kind()) :: [{String.t(), String.t()}]
  def discover(domains, kind \\ :api_key) do
    %{suffix: suffix} = Map.fetch!(@kinds, kind)

    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        table = AshPostgres.DataLayer.Info.table(resource),
        is_binary(table) and String.ends_with?(table, suffix),
        %{column_name: column} <- Samen.Catalog.fields(resource),
        String.ends_with?(column, "_token_digest"),
        uniq: true,
        do: {table, column}
  end

  defp host_repo(otp_app, k) do
    case Application.get_env(otp_app, :ecto_repos, []) do
      [repo | _] -> repo
      [] -> Mix.raise("mix #{k.task}: no :ecto_repos configured for #{inspect(otp_app)}")
    end
  end
end
