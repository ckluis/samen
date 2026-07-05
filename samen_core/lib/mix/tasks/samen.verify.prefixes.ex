defmodule Mix.Tasks.Samen.Verify.Prefixes do
  @shortdoc "Verify every storage column carries its resource's registered abbrev."

  @moduledoc """
  `mix samen.verify.prefixes` — verifier C2 (plan §C, Gate-0 fix task #2).

  ## What it checks

  Every physical column in the DB (for Samen-managed tables in `tam_table`) must
  start with the registered abbrev of its owning resource followed by `_`.

  This is the **fail-closed backstop** for the abbrev storage transformer (S0.2
  caveat F1 / Gate-0 fix task #2): a future attribute-adding transformer that runs
  AFTER Samen's own transformer could slip an unprefixed column past ordering.
  `catalog_sync` writes physical column names into `fld_field` at migration time;
  this verifier checks that every stored column name in the DB carries the expected
  prefix.

  ## Two layers

  1. **fld_field prefix check**: every row in `fld_field` has a `fld_column_name`
     that starts with `fld_table`'s resource abbrev + `_`. This catches catalog
     rows written for unprefixed columns (the migration was wrong).

  2. **physical column prefix check**: for every column in `information_schema`
     on a Samen-managed table, the physical column name must start with the
     resource's abbrev + `_`. This catches columns added outside the catalog (e.g.
     by a raw DDL migration that bypassed `catalog_sync`) — columns that might
     pass `catalog_parity` if they're in neither `fld_field` nor the physical DB,
     or columns that are physical but catalogued under the wrong name.

  The abbrev for each resource is looked up from `tam_table.tam_resource` →
  `Samen.Info.abbrev/1` — so the check keys on the registered abbrev, not a
  pattern guess.

  ## PII scalar column exception

  Scalar `pii_attribute` fields carry the `pii_<abbrev>_` prefix by design
  (e.g. `pii_pat_dob`, `pii_pat_mrn` for the `pat` resource). This is the
  doc's "PII routing note" — scalar PII columns are self-identifying as PII in
  their physical name. The verifier accepts both `<abbrev>_` and `pii_<abbrev>_`
  as valid prefixes for a resource's columns.

  ## Diagnostics

      FAIL: samen.verify.prefixes found 2 violation(s):
        • unprefixed column: com_contact.name [expected prefix: com_, resource: SamenCore.Support.Crm.Contact]
        • unprefixed fld_field row: com_contact.name [expected prefix: com_]

  ## Repo discovery

  Reads `:ecto_repos` from the host app's config. Pass `--repo MyApp.Repo` to
  override:

      mix samen.verify.prefixes --repo MyApp.Repo

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `:erlang.halt/1`).
  """

  use Mix.Task

  @task_name "samen.verify.prefixes"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} =
      OptionParser.parse(args, strict: [repo: :string])

    repos = resolve_repos(opts)

    violations =
      Enum.flat_map(repos, fn repo ->
        ensure_repo_started!(repo)
        check(repo)
      end)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Run the prefix check against `repo` and return a (possibly empty) list of
  human-readable violation strings.

  Separated from `run/1` so the test suite can call it without triggering
  `:erlang.halt/1`.
  """
  def check(repo) do
    # Build a map: table_name -> {resource_module_string, abbrev}
    table_abbrevs = load_table_abbrevs(repo)

    fld_violations = check_fld_field_prefixes(repo, table_abbrevs)
    physical_violations = check_physical_column_prefixes(repo, table_abbrevs)

    fld_violations ++ physical_violations
  end

  # ---------------------------------------------------------------------------
  # Repo resolution
  # ---------------------------------------------------------------------------

  defp resolve_repos(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        otp_app = Mix.Project.config()[:app]
        repos = Application.get_env(otp_app, :ecto_repos, [])

        if repos == [] do
          Mix.shell().error(
            "samen.verify.prefixes: no :ecto_repos configured for #{otp_app}. " <>
              "Pass --repo MyApp.Repo to override."
          )
        end

        repos

      repo_str ->
        [Module.concat([repo_str])]
    end
  end

  defp ensure_repo_started!(repo) do
    case repo.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "Could not start repo #{inspect(repo)}: #{inspect(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # Load table → {resource, abbrev} map from tam_table + Samen.Info
  # ---------------------------------------------------------------------------

  defp load_table_abbrevs(repo) do
    %{rows: rows} =
      repo.query!("SELECT tam_table_name, tam_resource FROM tam_table")

    rows
    |> Enum.map(fn [table_name, resource_str] ->
      abbrev = abbrev_for_resource(resource_str)
      {table_name, {resource_str, abbrev}}
    end)
    |> Enum.filter(fn {_t, {_r, abbrev}} -> is_binary(abbrev) end)
    |> Map.new()
  end

  # Resolve the resource module string back to a module and read its abbrev.
  # Returns nil if the module is not loaded, not a Samen resource, or not a
  # Spark DSL module (e.g. plain Ecto schemas like Samen.AuditEvent that are
  # catalogued but not Ash/Spark resources — their columns are prefixed by
  # convention but they have no Spark abbrev declaration).
  defp abbrev_for_resource(resource_str) do
    module = Module.concat([resource_str])

    with {:module, ^module} <- Code.ensure_compiled(module),
         abbrev when is_binary(abbrev) <- Samen.Info.abbrev(module) do
      abbrev
    else
      _ -> nil
    end
  rescue
    # Spark raises ArgumentError when get_opt is called on a non-DSL module.
    ArgumentError -> nil
  end

  # ---------------------------------------------------------------------------
  # Check 1: fld_field rows
  # ---------------------------------------------------------------------------

  defp check_fld_field_prefixes(repo, table_abbrevs) do
    managed_tables = Map.keys(table_abbrevs)

    if managed_tables == [] do
      []
    else
      %{rows: rows} =
        repo.query!(
          "SELECT fld_table_name, fld_column_name FROM fld_field " <>
            "WHERE fld_table_name = ANY($1::text[]) " <>
            "ORDER BY fld_table_name, fld_column_name",
          [managed_tables]
        )

      for [table_name, col_name] <- rows,
          {_resource_str, abbrev} = Map.get(table_abbrevs, table_name),
          not valid_prefix?(col_name, abbrev) do
        "unprefixed fld_field row: #{table_name}.#{col_name} [expected prefix: #{abbrev}_]"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Check 2: physical columns in information_schema
  # ---------------------------------------------------------------------------

  defp check_physical_column_prefixes(repo, table_abbrevs) do
    managed_tables = Map.keys(table_abbrevs)

    if managed_tables == [] do
      []
    else
      %{rows: rows} =
        repo.query!(
          "SELECT table_name, column_name " <>
            "FROM information_schema.columns " <>
            "WHERE table_schema = 'public' " <>
            "AND table_name = ANY($1::text[]) " <>
            "ORDER BY table_name, column_name",
          [managed_tables]
        )

      for [table_name, col_name] <- rows,
          {resource_str, abbrev} = Map.get(table_abbrevs, table_name),
          not valid_prefix?(col_name, abbrev) do
        "unprefixed column: #{table_name}.#{col_name} [expected prefix: #{abbrev}_, resource: #{resource_str}]"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Prefix validation
  #
  # A column is valid if its name starts with either:
  #   • "<abbrev>_"      — the normal Samen storage prefix (all non-PII columns
  #                         and composite PII columns)
  #   • "pii_<abbrev>_"  — the PII scalar prefix (e.g. pii_pat_dob, pii_pat_mrn)
  #                         assigned by MaterializePii for scalar pii_attribute fields
  #
  # This matches the doc's "PII routing note" and the MaterializePii transformer's
  # `source_for/2` logic. A column carrying neither prefix is unprefixed and fails.
  # ---------------------------------------------------------------------------

  defp valid_prefix?(col_name, abbrev) do
    String.starts_with?(col_name, abbrev <> "_") or
      String.starts_with?(col_name, "pii_" <> abbrev <> "_")
  end
end
