defmodule Mix.Tasks.Samen.Verify.PiiClassify do
  @shortdoc "Fail build on NEW plain-typed string/date columns that look like PII."

  @moduledoc """
  `mix samen.verify.pii_classify` — verifier C4 (plan §C; T1.8c).

  ## What it checks

  For every NEW plain-typed `:string` or `:date` attribute on an Ash resource,
  this task runs a two-axis heuristic:

    1. **Identifier-shape name** — the logical attribute name matches a known PII
       identifier token (`ssn`, `dob`, `mrn`, `cdl`, `tax_id`, `email`, `phone`,
       and a wider set of common PII field name fragments).

    2. **PII-shaped sample/seed values** — the attribute's `:default` or
       `:constraints` carry a value that looks like an email address, an SSN, or
       a phone number.

  A **hit on either axis fails the build** until the column is either:

    * declared in a `pii do … end` block as `pii_attribute` (vault-routed), OR
    * cleared by a **review-gated `non_pii!` override** with a DISTINCT second
      reviewer (`cleared_by != reviewed_by`).

  A self-review `non_pii!` (same `cleared_by` and `reviewed_by`) is rejected
  by `Samen.NonPii.register/1` and therefore also fails this verifier — the
  distinct-party discipline matches reveal grants (plan OD-11).

  Every accepted `non_pii!` override must be **registered in the `Samen.NonPii`
  registry** (T1.7's registry), which is what this verifier reads to determine if
  a column has been cleared.

  ## "New" columns

  A column is "new" if it is NOT present in the committed `schema.dict.json`
  baseline. The baseline is loaded from `schema.dict.json` in the mix project
  root (configurable via `--baseline <path>`). If the file does not exist, ALL
  plain-typed columns are treated as new (none are grandfathered).

  Pre-existing reviewed columns in the baseline do not re-flag — they were
  evaluated at the time the baseline was committed.

  ## Flag-on-hit, NOT assume-all-strings-are-PII

  An attribute is only flagged if its name or default/constraint values hit the
  heuristic. A plain `:notes` or `:description` column does not flag. The
  heuristic, like any heuristic, can miss a non-obvious name — the `non_pii!`
  review gate, not the scanner, is the backstop for a miss.

  ## Non-emptiness floor (fail-closed on empty discovery)

  A classify check that discovers ZERO resources verifies nothing — a mis-keyed
  `:ash_domains` would otherwise turn this gate green in every app. The task
  FAILS CLOSED (exit 1) when resource discovery is empty, the same
  non-emptiness floor as `samen.verify.vault_declared_parity`,
  `samen.verify.oban_queues`, and `samen.verify.erasure_completeness`.

  ## Exit code

  Exits 0 when no violations are found (fail-closed via `:erlang.halt/1` on
  violation — no cleanup hook can swallow the exit code). Exits 1 when
  resource discovery is empty (a vacuous check must not pass).

  ## Usage

      mix samen.verify.pii_classify
      mix samen.verify.pii_classify --baseline priv/schema.dict.json
      mix samen.verify.pii_classify --domain MyApp.Crm

  ## Repo / registry

  Reads the `Samen.NonPii` registry to find accepted overrides. The repo is
  discovered from `:non_pii_repo` / `:reveal_grant_repo` / `:verify_repo` in
  the app config (the same chain as `Samen.NonPii`). If no repo is configured
  the registry check is skipped (all plain-typed columns are uncleared).
  """

  use Mix.Task

  alias Samen.PiiClassify
  alias Samen.NonPii

  @task_name "samen.verify.pii_classify"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          baseline: :string,
          domain: [:string, :keep]
        ]
      )

    Mix.Task.run("app.start")

    baseline_path = Keyword.get(opts, :baseline, "schema.dict.json")
    baseline = PiiClassify.load_baseline(baseline_path)

    domain_args = Keyword.get_values(opts, :domain)
    resources = resolve_resources(domain_args)
    halt_if_no_resources!(resources)

    registry_entries = load_registry()

    violations =
      resources
      |> PiiClassify.scan_resources(baseline, registry_entries)
      |> Enum.map(&PiiClassify.format_flag/1)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Run the classify check and return violations (as strings), without halting.

  Separated from `run/1` so tests can call it directly and inspect violations
  without triggering `:erlang.halt/1`.

  ## Parameters

    * `resources` — a list of resource module atoms to scan.
    * `baseline` — a `MapSet.t({table_name, column_name})` baseline set.
    * `registry_entries` — a list of `%Samen.NonPii.Entry{}` rows.
  """
  @spec check([module()], PiiClassify.baseline_set(), [term()]) :: [String.t()]
  def check(resources, baseline \\ MapSet.new(), registry_entries \\ []) do
    resources
    |> PiiClassify.scan_resources(baseline, registry_entries)
    |> Enum.map(&PiiClassify.format_flag/1)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  # A2 non-emptiness floor: empty discovery means a mis-keyed :ash_domains (or a
  # broken --domain list), NOT a clean scan — a green "OK" on zero resources is
  # indistinguishable from a green on a real one. Same fail-closed shape as
  # `vault_declared_parity.halt_if_no_resources!/1`.
  defp halt_if_no_resources!(resources) do
    if resources == [] do
      IO.puts("")

      IO.puts(
        "FAIL: #{@task_name} discovered ZERO resources — cannot classify PII columns. " <>
          "Configure the host's :ash_domains (or pass --domain) so the resources are " <>
          "introspectable. A vacuous classify check must not pass (fail-closed)."
      )

      IO.puts("")
      :erlang.halt(1)
    end
  end

  defp load_registry do
    try do
      NonPii.entries()
    rescue
      _ ->
        # Registry unavailable (e.g. repo not started, DB not available).
        # Fail safe: return an empty list — no overrides are accepted.
        []
    catch
      :exit, _ -> []
    end
  end
end
