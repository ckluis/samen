defmodule Mix.Tasks.Samen.Audit.FreeformProjection do
  @shortdoc "One-shot audit: list freeform columns excluded from the CDC projection (ADR-015)."

  @moduledoc """
  `mix samen.audit.freeform_projection` — the ADR-015 §"Migration" step-1 audit
  sweep.

  The default-deny classifier flip (G3) re-classifies every freeform content
  column (`:string`/`:ci_string`/`:text`/`:map`/`:jsonb` + unknown/custom types)
  that is neither vault-routed (`pii_attribute`) nor `non_pii!`-cleared as
  `:plaintext_pii` — **excluded** from `Samen.Cdc.Projection.project/1`. Before
  the flip these columns silently mirrored as `:metadata`.

  This task lists every such column across the app's configured Ash domains so
  the one-time triage (ADR-015 migration step 2) can decide, per column:

    * genuine PII → declare `pii_attribute` (vault-route) → mirrors as `:token`;
    * genuinely safe → fix the type (enum it) OR add a two-reviewer `non_pii!`
      registry entry → mirrors as a safe scalar;
    * unsure → **leave excluded** (the conservative default — exclusion is the
      safe state, this task exits 0 either way).

  ## Output

  One line per excluded column:

      table.column  resource=Module  logical=:name  type=Ash.Type.String

  plus a summary count. The task is an AUDIT, not a verifier: it always exits 0.
  The fail-closed enforcement lives in `pii_classify`/`no_plaintext_pii` and the
  projection itself.

  ## Registry

  `non_pii!` clearances are read from the live `Samen.NonPii` registry (the same
  fail-closed lookup the projection uses). If the app registers clearances at
  boot/seed time via a `register_all/0`-style setup module, run that first (or
  run under `MIX_ENV=test` after the test bootstrap) so cleared columns do not
  appear as excluded.

  ## Usage

      mix samen.audit.freeform_projection
      mix samen.audit.freeform_projection --domain MyApp.Crm
  """
  use Mix.Task

  alias Samen.Cdc.Projection

  @task_name "samen.audit.freeform_projection"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _} = OptionParser.parse(args, strict: [domain: :keep])

    Mix.Task.run("app.start")

    excluded =
      opts
      |> Keyword.get_values(:domain)
      |> resolve_resources()
      |> excluded_columns()

    print_report(excluded)
  end

  @doc """
  Compute the excluded (`:plaintext_pii`) columns for `resources`.

  Returns a list of `%{table: t, column: c, resource: mod, logical: atom, type: type}`
  maps, sorted by `{table, column}`. Separated from `run/1` so tests can call it
  directly. `opts` are forwarded to `Projection.classify_columns/2` (e.g.
  `:non_pii_entries` injection).
  """
  @spec excluded_columns([module()], keyword()) :: [map()]
  def excluded_columns(resources, opts \\ []) do
    resources
    |> Enum.flat_map(fn resource ->
      table = Projection.table_name(resource)
      classified = Map.new(Projection.classify_columns(resource, opts))

      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.flat_map(fn attr ->
        col = to_string(attr.source || attr.name)

        if Map.get(classified, col) == :plaintext_pii do
          [%{table: table, column: col, resource: resource, logical: attr.name, type: attr.type}]
        else
          []
        end
      end)
    end)
    |> Enum.sort_by(fn %{table: t, column: c} -> {t, c} end)
  end

  defp print_report([]) do
    Mix.shell().info(
      "#{@task_name}: OK — no freeform columns are excluded from the CDC projection " <>
        "(every freeform column is vault-routed or non_pii!-cleared)."
    )
  end

  defp print_report(excluded) do
    Mix.shell().info(
      "#{@task_name}: #{length(excluded)} freeform column(s) are EXCLUDED from the " <>
        "CDC projection under default-deny (ADR-015). Triage each: vault-route " <>
        "(pii_attribute), clear via two-reviewer non_pii!, or leave excluded (safe default).\n"
    )

    Enum.each(excluded, fn %{table: t, column: c, resource: r, logical: l, type: ty} ->
      Mix.shell().info(
        "  #{t}.#{c}  resource=#{inspect(r)}  logical=#{inspect(l)}  type=#{inspect(ty)}"
      )
    end)
  end

  defp resolve_resources([]) do
    otp_app = Mix.Project.config()[:app]

    domains =
      Application.get_env(otp_app, :ash_domains, []) ++
        Application.get_env(:ash, :domains, [])

    Samen.Catalog.resource_modules(Enum.uniq(domains))
  end

  defp resolve_resources(domain_strings) do
    domains =
      Enum.map(domain_strings, fn ds ->
        mod = Module.concat([ds])

        case Code.ensure_compiled(mod) do
          {:module, ^mod} ->
            mod

          _ ->
            Mix.raise("Domain module #{inspect(mod)} could not be compiled/loaded.")
        end
      end)

    Samen.Catalog.resource_modules(domains)
  end
end
