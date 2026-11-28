defmodule Mix.Tasks.Samen.Gen.ApiKeyScopes do
  @shortdoc "Write the migration that gives every existing key with no scopes the authority its minter role already granted."

  @moduledoc """
  `mix samen.gen.api_key_scopes` — the data step for the release that enforces an API key's scopes on every request. A key whose
  `scopes` is empty authorizes nothing from then on; keys minted before the release could have an empty `scopes` and still
  act with their minter's role. This writes the migration that gives each of them, once, the authority it already had. Run it
  inside the app, then `mix ecto.migrate`, before or with the upgrade.

  It writes ONE migration, `<ts>_api_key_scopes.exs`, of literal SQL, one pair of statements per key table, run in committed
  batches of 5,000 rows (`chunked_backfill/4`):

    * a key whose `minter_role` is `owner`, `admin` or `member` and whose `scopes` is empty or NULL gets `{"all": ["read", "write"]}`;
    * a key whose `minter_role` is `viewer` and whose `scopes` is empty or NULL gets `{"all": ["read"]}`.

  A key with scopes already is not touched, nor is one with no (or an unknown) `minter_role`: it authenticates as no one and
  stays refused. A revoked or expired key is updated too (harmless; it cannot authenticate). The statements only match
  rows that are still empty, so running the migration again changes nothing. `down` does nothing: a restored empty set would
  be indistinguishable from a key whose scopes were chosen. Re-mint a key, or edit its scopes, to narrow it below the role.

  Which tables: every resource of the app's `:ash_domains` (`--domain`, repeatable, replaces them) whose table ends in `_api_key`
  and that has a `*_scopes` and a `*_minter_role` attribute (`--key table:scopes_column:role_column`, repeatable; when given,
  ONLY these are used, nothing is discovered). A table already named by a `*_api_key_scopes.exs` migration in the app's migrations
  is skipped; when nothing is left it writes nothing and says so, so a re-run is harmless. The table and column names are LITERAL.

  ## Usage

      mix samen.gen.api_key_scopes [--out path] [--timestamp 20261127100000] [--domain MyApp.Identity …] [--key table:scopes_col:role_col …]
  """
  use Mix.Task

  @suffix "_api_key"

  @impl Mix.Task
  def run(argv) do
    opts = Samen.Gen.Args.parse!("samen.gen.api_key_scopes", argv, out: :string, timestamp: :string, domain: :keep, key: :keep)

    Mix.Task.run("app.config")
    Mix.Task.run("compile")

    otp_app = Mix.Project.config()[:app]
    repo = host_repo(otp_app)
    out_dir = Keyword.get(opts, :out) || Ecto.Migrator.migrations_path(repo)
    timestamp = Keyword.get(opts, :timestamp) || Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")

    keys =
      case Keyword.get_values(opts, :key) do
        [] -> discover(domains(otp_app, Keyword.get_values(opts, :domain)))
        triples -> Enum.map(triples, &parse_key!/1)
      end

    if keys == [], do: Mix.raise("mix samen.gen.api_key_scopes: no API-key table found; pass --key table:scopes_column:role_column")

    generate(repo, keys, out_dir, timestamp)
  end

  @doc """
  Write the migration for `keys` (`[{table, scopes_column, role_column}]`) into `out_dir`, skipping tables a migration there
  already backfills. Returns the path, or `nil` when there was nothing to write.
  """
  @spec generate(module(), [{String.t(), String.t(), String.t()}], Path.t(), String.t()) :: Path.t() | nil
  def generate(repo, keys, out_dir, timestamp) do
    existing = existing_sources(out_dir)
    {done, todo} = Enum.split_with(Enum.sort(Enum.uniq(keys)), fn {t, _, _} -> present?(existing, t) end)

    for {t, _, _} <- done,
        do: Mix.shell().info("samen.gen.api_key_scopes: #{t} is already backfilled by a migration; skipped")

    if todo == [] do
      Mix.shell().info("samen.gen.api_key_scopes: nothing to do")
      nil
    else
      path = Path.join(out_dir, "#{timestamp}_api_key_scopes.exs")
      File.mkdir_p!(out_dir)
      File.write!(path, render(repo, todo, timestamp))
      Mix.shell().info("samen.gen.api_key_scopes: wrote #{path} (#{length(todo)} table(s))")
      path
    end
  end

  @empty "{}"

  @doc "The migration source for `keys` on `repo` at `timestamp` (pure)."
  @spec render(module(), [{String.t(), String.t(), String.t()}], String.t()) :: String.t()
  def render(repo, keys, timestamp) do
    ups =
      Enum.map_join(keys, "\n\n", fn {t, s, r} ->
        """
            chunked_backfill(repo(), "#{t}", ~s|#{s} = '{"all":["read","write"]}'::jsonb|,
              where: "(#{s} IS NULL OR #{s} = '#{@empty}'::jsonb) AND #{r} IN ('owner', 'admin', 'member')"
            )

            chunked_backfill(repo(), "#{t}", ~s|#{s} = '{"all":["read"]}'::jsonb|,
              where: "(#{s} IS NULL OR #{s} = '#{@empty}'::jsonb) AND #{r} = 'viewer'"
            )\
        """
      end)

    cols = Enum.map_join(keys, ", ", fn {t, s, r} -> "`#{t}.#{s}` (role `#{t}.#{r}`)" end)

    """
    defmodule #{inspect(repo)}.Migrations.ApiKeyScopes#{timestamp} do
      @moduledoc \"\"\"
      API-key scopes are enforced on every request, and a key with no scopes authorizes nothing. Before that, a key minted with an
      empty `scopes` acted with its minter's role alone; this gives each such key the authority it already had: an owner, admin or
      member key `{"all": ["read", "write"]}`, a viewer key `{"all": ["read"]}`. Tables: #{cols}. Generated by
      `mix samen.gen.api_key_scopes`.

      Table, column and role names are LITERAL: this migration means the same thing forever. Committed batches of 5,000 rows
      (hence `@disable_ddl_transaction true`). A key that already has scopes, or has no known minter role, is not touched, and
      every statement only matches rows that are still empty, so running it again changes nothing. `down` does nothing: an empty
      set it restored could not be told from a deliberate one.
      \"\"\"
      use Samen.Migration, phase: :expand
      @disable_ddl_transaction true
      @disable_migration_lock true

      def up do
    #{ups}
      end

      def down do
        :ok
      end
    end
    """
  end

  defp existing_sources(dir), do: dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.map(&File.read!/1)

  # a migration of this task's output that names the table
  defp present?(sources, table),
    do: Enum.any?(sources, &(String.contains?(&1, ".Migrations.ApiKeyScopes") and String.contains?(&1, ~s|"#{table}"|)))

  defp parse_key!(triple) do
    case String.split(triple, ":") do
      [table, scopes, role] when table != "" and scopes != "" and role != "" -> {table, scopes, role}
      _ -> Mix.raise("mix samen.gen.api_key_scopes: --key expects table:scopes_column:role_column, got #{inspect(triple)}")
    end
  end

  defp domains(otp_app, []), do: Application.get_env(otp_app, :ash_domains, [])
  defp domains(_otp_app, names), do: Enum.map(names, &Module.concat([&1]))

  @doc """
  The `{table, scopes_column, role_column}` of every API-key resource in `domains`. The columns are the STORED ones
  (`Samen.Catalog.fields/1`'s `column_name`, the abbrev-prefixed `:source`), never the logical attribute names: the emitted
  migration must name columns that exist in the database.
  """
  @spec discover([module()]) :: [{String.t(), String.t(), String.t()}]
  def discover(domains) do
    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        table = AshPostgres.DataLayer.Info.table(resource),
        is_binary(table) and String.ends_with?(table, @suffix),
        columns = for(%{column_name: c} <- Samen.Catalog.fields(resource), do: c),
        scopes <- Enum.filter(columns, &String.ends_with?(&1, "_scopes")),
        role <- Enum.filter(columns, &String.ends_with?(&1, "_minter_role")),
        uniq: true,
        do: {table, scopes, role}
  end

  defp host_repo(otp_app) do
    case Application.get_env(otp_app, :ecto_repos, []) do
      [repo | _] -> repo
      [] -> Mix.raise("mix samen.gen.api_key_scopes: no :ecto_repos configured for #{inspect(otp_app)}")
    end
  end
end
