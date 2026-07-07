defmodule Mix.Tasks.Samen.Verify.VaultDeclaredParity do
  @shortdoc "Fail build on a vault-shaped `pii_*` column with no matching pii_attribute route."

  @moduledoc """
  `mix samen.verify.vault_declared_parity` — verifier C6 (Phase-3 cross-scope
  review fix F3.1).

  ## The gap this closes

  The C4 `pii_classify` verifier flags NEW plain-typed columns whose *logical
  name* hits a PII heuristic token (`email`, `ssn`, `dob`, …). But a **free-text
  🔒 field** whose logical name is NOT in that token-list (`body`,
  `rendered_body`, `signing_secret`) escapes the heuristic entirely. So if a scope
  author *de-vaults* such a field — drops the `pii do` route while the migration
  still carries the `pii_<abbrev>_<name>` column — the whole verifier gate
  (`catalog_parity`, `prefixes`, `pii_reads`, `pii_classify`, `no_plaintext_pii`)
  stays green, and only the scope's hand-written `*_vault_routing_test.exs` catches
  it. That was the exact hole the T3.14 de-vault sabotage probe exploited: removing
  the `pii do` block for `message.body` left `pii_smg_body` in the DB while the
  resource dropped the route, and no *verifier* failed.

  This verifier fails **closed** on that mismatch.

  ## What it checks

  The `pii_<abbrev>_<name>` column-name shape is the storage convention the
  `MaterializePii` transformer emits for a **scalar vault-routed** field
  (moduledoc there: `source: :"pii_<abbrev>_<name>"`). A physical column matching
  `^pii_[a-z]{3}_` is therefore a *promise* that the field is vault-routed. This
  task asserts that promise against the resource declarations:

  > For every physical column on a Samen-managed table whose name matches
  > `^pii_[a-z]{3}_`, some resource in the host's `ash_domains` must declare a
  > `pii_attribute` whose materialized storage column is exactly that column
  > (`Samen.Pii.Info.vault_routed_columns/1`).

  A `pii_*` column with **no** matching route is a `de-vaulted PII column`
  violation — the DB still stores what the storage name promises is vaulted PII,
  but the resource no longer routes writes through the vault (so plaintext can land
  in that column) and no reveal boundary guards reads.

  This keys on the **DB truth** (the physical column that outlives a code edit),
  not on the resource attribute — which is precisely why it catches a de-vault the
  resource-only verifiers miss: after a de-vault the resource introspection no
  longer mentions the column at all, but the column is still in Postgres.

  Composite PII fields (FullName/Emails/Phones) route *by vault name* and carry NO
  `pii_` prefix (`per_full_name`), so they are outside this shape by design and are
  covered by the per-scope vault-routing test + C3/C5. This verifier is the
  fail-closed backstop specifically for the **scalar `pii_`-prefixed** column shape.

  ## Fail-closed on empty discovery

  If zero resources are discovered (host `ash_domains` unconfigured / mis-keyed),
  the parity check would be vacuous — every `pii_*` column would be "unrouted" and
  fail, OR (worse) no columns would be scanned. To avoid a misleading pass on a
  mis-wired host, if no resources are discovered the task exits 1 with a config
  diagnostic (same posture as `pii_reads`).

  ## Allow-list

  A genuinely non-Ash `pii_*` column (raw-DDL operational column not backed by a
  resource attribute) may be declared in app config, mirroring
  `catalog_parity_allow_list`:

      config :my_app, :vault_declared_parity_allow_list, [
        {"some_table", "pii_xyz_thing"}
      ]

  Allow-listed pairs are excluded from the unrouted-column check. Use sparingly —
  the whole point of the check is that a `pii_*` column is a vault promise.

  ## Repo / domain discovery

  Repo(s) from `:ecto_repos` (override with `--repo MyApp.Repo`); resources from
  the host's `:ash_domains` (the same convention C1/C4 use).

  ## Exit code

  Exits 0 when no violations, 1 on any violation (fail-closed via `:erlang.halt/1`
  — no cleanup hook can swallow the exit code).
  """

  use Mix.Task

  @task_name "samen.verify.vault_declared_parity"

  # A vault storage-name shape: `pii_` + exactly three lowercase letters (the
  # resource abbrev) + `_`. This is what MaterializePii emits for scalar PII.
  @vault_column_pattern ~r/^pii_[a-z]{3}_/

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} = OptionParser.parse(args, strict: [repo: :string])

    resources = discover_resources()
    halt_if_no_resources!(resources)

    routed = routed_vault_columns(resources)
    allow_list = load_allow_list()

    repos = resolve_repos(opts)

    violations =
      Enum.flat_map(repos, fn repo ->
        ensure_repo_started!(repo)
        check(repo, routed, allow_list)
      end)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Run the parity check against `repo` and return violation strings.

  * `routed` — a `MapSet` of `{table_name, column_name}` pairs that ARE declared
    vault-routed by some resource (from `Samen.Pii.Info.vault_routed_columns/1`).
  * `allow_list` — a `MapSet` of `{table_name, column_name}` intentional non-route
    exceptions.

  Separated from `run/1` so tests can call it directly without `:erlang.halt/1`.
  """
  def check(repo, routed, allow_list \\ MapSet.new()) do
    managed = managed_table_names(repo)

    repo
    |> vault_shaped_columns(managed)
    |> MapSet.to_list()
    |> Enum.sort()
    |> Enum.reject(fn pair -> MapSet.member?(routed, pair) end)
    |> Enum.reject(fn pair -> MapSet.member?(allow_list, pair) end)
    |> Enum.map(fn {t, c} ->
      "de-vaulted PII column: #{t}.#{c} matches the vault storage shape " <>
        "(pii_<abbrev>_<name>) but no resource declares a matching pii_attribute " <>
        "route (the column is still in the DB while the vault route was dropped)"
    end)
  end

  @doc """
  The `{table_name, column_name}` set that resources DO declare as vault-routed
  (the positive side of parity). Public so tests can assert on it.
  """
  def routed_vault_columns(resources) do
    for resource <- resources,
        table = Samen.Catalog.table_name(resource),
        is_binary(table),
        col <- Samen.Pii.Info.vault_routed_columns(resource),
        into: MapSet.new() do
      {table, to_string(col)}
    end
  end

  # ---------------------------------------------------------------------------
  # Resource / repo discovery
  # ---------------------------------------------------------------------------

  defp discover_resources do
    otp_app = Mix.Project.config()[:app]

    domains =
      Application.get_env(otp_app, :ash_domains, []) ++
        Application.get_env(:samen_core, :ash_domains, []) ++
        Application.get_env(:ash, :domains, [])

    Samen.Catalog.resource_modules(Enum.uniq(domains))
  end

  defp halt_if_no_resources!(resources) do
    if resources == [] do
      IO.puts("")

      IO.puts(
        "FAIL: #{@task_name} discovered ZERO resources — cannot verify vault parity. " <>
          "Configure the host's :ash_domains so the resources are introspectable. " <>
          "A vacuous parity check must not pass (fail-closed)."
      )

      IO.puts("")
      :erlang.halt(1)
    end
  end

  defp resolve_repos(opts) do
    case Keyword.get(opts, :repo) do
      nil ->
        otp_app = Mix.Project.config()[:app]
        repos = Application.get_env(otp_app, :ecto_repos, [])

        if repos == [] do
          Mix.shell().error(
            "#{@task_name}: no :ecto_repos configured for #{otp_app}. " <>
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
  # Allow-list
  # ---------------------------------------------------------------------------

  defp load_allow_list do
    otp_app = Mix.Project.config()[:app]

    Application.get_env(otp_app, :vault_declared_parity_allow_list, [])
    |> Enum.map(fn {t, c} -> {t, c} end)
    |> MapSet.new()
  end

  # ---------------------------------------------------------------------------
  # DB queries
  # ---------------------------------------------------------------------------

  defp managed_table_names(repo) do
    %{rows: rows} = repo.query!("SELECT tam_table_name FROM tam_table")
    MapSet.new(Enum.map(rows, fn [t] -> t end))
  end

  # Every physical column on a managed table whose name matches the vault shape.
  defp vault_shaped_columns(repo, managed) do
    if MapSet.size(managed) == 0 do
      MapSet.new()
    else
      table_list = MapSet.to_list(managed)

      %{rows: rows} =
        repo.query!(
          "SELECT table_name, column_name " <>
            "FROM information_schema.columns " <>
            "WHERE table_schema = 'public' " <>
            "AND table_name = ANY($1::text[]) " <>
            "AND column_name ~ '^pii_[a-z]{3}_' " <>
            "ORDER BY table_name, column_name",
          [table_list]
        )

      rows
      |> Enum.map(fn [t, c] -> {t, c} end)
      |> Enum.filter(fn {_t, c} -> Regex.match?(@vault_column_pattern, c) end)
      |> MapSet.new()
    end
  end
end
