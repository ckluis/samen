defmodule Mix.Tasks.Samen.Verify.Indexes do
  @shortdoc "Verify every org-scoped resource has an (org_id, <keyset sort>, id) index in the live database."

  @moduledoc """
  `mix samen.verify.indexes` — the tenant-index verifier (ARCH-4).

  Every org-scoped Ash resource (`org_id` attribute + Postgres table + `Samen.Policy.OrgScope`
  in its policies — see `Samen.Indexing`) must have a plain btree index whose leading columns
  are `(org_id, <keyset sort>, id)`, where `<keyset sort>` is the resource's `keyset_sort`
  (`use Samen.Resource, keyset_sort: :name`; none = `(org_id, id)`). That is the shape
  `Samen.Web.Reads` pages walk; without it every org-scoped keyset page is a sequential scan
  that gets slower as the table grows. The mechanism is in `Samen.Indexing`.

  ## Source of truth: the live catalog, not the resource DSL

  This foundry's hosts write their schema as hand-written/templated `Samen.Migration`s (not
  `ash_postgres.generate_migrations`), so a `custom_indexes` declaration on a resource can say an
  index exists that no migration ever created. The planner only uses indexes the database has, so
  the verifier reads `pg_index` after the host's migrations ran (the host `ci.sh` bootstrap) —
  the same convention as `catalog_parity` / `prefixes` / `pii_reads`. A partial, invalid,
  not-yet-ready, expression-led, non-btree, or mixed-direction index does NOT count.

  ## Fail-honest

  A resource the verifier cannot inspect (its policies cannot be read, its `keyset_sort`
  names no stored attribute, its table is absent from the live database, the catalog query
  fails) is a VIOLATION, never a silent pass. So is a run that finds no domains or no
  org-scoped resource at all: a verifier that scanned nothing proved nothing.

  ## Exemptions

  `@exempt` below maps a resource module to the reason it needs no index. Each reason must be
  literally true; an entry whose resource is no longer org-scoped, or does have the index, is
  itself reported (a stale exemption is a violation), so the list cannot rot. It is empty.

  ## Usage

      mix samen.verify.indexes
      mix samen.verify.indexes --domain MyApp.Crm

  Exits 0 when clean, 1 on any violation (via `Samen.Verifier`). The host's DB must be migrated.
  """
  use Mix.Task

  @task_name "samen.verify.indexes"

  # resource module => the literal reason it is exempt. Keep this as short as honesty allows.
  @exempt %{}

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _rest, _} = OptionParser.parse(args, strict: [domain: :keep])

    Samen.Verifier.halt_if_violations(@task_name, violations(domains: domains(opts)))
  end

  @doc """
  The violation strings for `opts[:domains]`. Separated from `run/1` so tests can assert on it
  without halting the VM. `opts[:exempt]` overrides the exemption map (tests only).
  """
  @spec violations(keyword()) :: [String.t()]
  def violations(opts) do
    domains = Keyword.get(opts, :domains, [])
    exempt = Keyword.get(opts, :exempt, @exempt)

    if domains == [] do
      ["no Ash domains are configured — nothing was inspected, so nothing is proven"]
    else
      {resources, unclassified} = Samen.Indexing.org_scoped(domains)

      empty =
        if resources == [] and unclassified == [],
          do: ["the configured domains contain no org-scoped resource — nothing was inspected"],
          else: []

      empty ++
        Enum.map(unclassified, fn {_resource, reason} -> "cannot inspect: #{reason}" end) ++
        Enum.flat_map(resources, &check(&1, exempt)) ++
        stale_exemptions(exempt, resources)
    end
  end

  defp check(resource, exempt) do
    if Map.has_key?(exempt, resource), do: [], else: check_one(resource)
  end

  defp check_one(resource) do
    with {:ok, spec} <- Samen.Indexing.spec(resource),
         repo = repo(resource),
         true <- repo != nil or {:error, "#{inspect(resource)} declares no repo"},
         :ok <- ensure_repo_started(repo),
         {:ok, indexes} <- Samen.Indexing.live_indexes(repo, spec.schema, spec.table) do
      if Enum.any?(indexes, &Samen.Indexing.serves?(&1, spec)) do
        []
      else
        [missing(spec, indexes)]
      end
    else
      {:error, reason} -> ["cannot inspect #{inspect(resource)}: #{reason}"]
    end
  end

  defp repo(resource), do: AshPostgres.DataLayer.Info.repo(resource, :read)

  # A verifier run (`mix samen.verify.*`) has the app compiled but not necessarily its repo
  # started; start the repo a resource declares. One that cannot start (e.g. a resource wired
  # to a repo this host does not have) is "cannot inspect" — a violation, never a skip.
  defp ensure_repo_started(repo) do
    if Process.whereis(repo) do
      :ok
    else
      case repo.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, "repo #{inspect(repo)} could not be started: #{inspect(reason)}"}
      end
    end
  end

  defp missing(spec, indexes) do
    have =
      case indexes do
        [] -> "no index at all"
        _ -> "has " <> Enum.map_join(indexes, ", ", &describe/1)
      end

    "#{inspect(spec.resource)} (#{spec.table}): no index serves the org-scoped keyset page — " <>
      "need btree (#{Enum.join(spec.columns, ", ")}); #{have}. " <>
      "Generate the migration with `mix samen.gen.indexes`."
  end

  defp describe(index), do: "#{index.name}(#{Enum.map_join(index.keys, ", ", &to_string/1)})"

  defp stale_exemptions(exempt, resources) do
    for {resource, _reason} <- exempt, resource not in resources do
      "stale exemption: #{inspect(resource)} is exempt but is not an org-scoped resource of the " <>
        "configured domains — delete the entry"
    end
  end

  defp domains(opts) do
    case Keyword.get_values(opts, :domain) do
      [] ->
        otp_app = Mix.Project.config()[:app]
        Application.get_env(otp_app, :ash_domains, [])

      names ->
        Enum.map(names, &Module.concat([&1]))
    end
  end
end
