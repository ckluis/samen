defmodule Mix.Tasks.Samen.Verify.NoPlaintextPii do
  @shortdoc "CI-mode oracle: token-only-downstream invariant over every projected tier so far."

  @moduledoc """
  `mix samen.verify.no_plaintext_pii` — verifier C5, **CI MODE ONLY** (plan §C;
  T1.8d).

  ## What it checks (CI mode)

  The **token-only-downstream** invariant over every projected tier that exists so
  far (doc §runs oracle block, CI-mode half):

    * **(a)** every vault-routed declaration's storage column is the token type
      (`Samen.Type.VaultField`), never a plaintext PII type;
    * **(b)** the projected audit-row surfaces (the T1.6/T1.7 reveal-grant /
      erasure lifecycle rows) and the catalog itself expose only bounded-ID /
      token / enum / metadata columns — never a plaintext PII column;
    * **(c)** `db_statement` is `:disabled` if `opentelemetry_ecto` is present
      (config-level assertion — acceptable at the kernel layer per T1.8d; the live
      runtime assertion is Phase 2 T2.6);
    * **(d)** registered `non_pii!` columns are **exempt-but-listed** (plaintext-
      at-rest by design) — printed, never failing the build.

  ## NOT this task (Phase 2)

  The **post-shred oracle** (`--subject <uuid> --tiers all`) that scans live /
  replica / rollup / audit / backup-PITR / KMS attestation for a specific erased
  subject is Phase 2 (T2.9). This task deliberately does NOT accept `--subject` /
  `--tiers`. The tier registry is designed EXTENSIBLY so T2.9 adds
  `cdc_mirror` / `rollup` / `trace_sink` tiers without touching this harness (see
  `Samen.NoPlaintextPii.Tier`).

  ## Exit code (fail-closed)

  Exits 0 when there are no `:violation` findings, 1 otherwise (via
  `:erlang.halt/1`, so no cleanup hook can swallow the code). `:exempt` findings
  (registered `non_pii!` columns) are LISTED but never affect the exit code.

  ## Usage

      mix samen.verify.no_plaintext_pii
      mix samen.verify.no_plaintext_pii --repo MyApp.Repo
      mix samen.verify.no_plaintext_pii --domain MyApp.Crm
  """

  use Mix.Task

  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Finding

  @task_name "samen.verify.no_plaintext_pii"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args, strict: [repo: :string, domain: [:string, :keep]])

    Mix.Task.run("app.start")

    run_opts = build_run_opts(opts)
    ensure_repo_started!(run_opts)
    {:ok, findings} = NoPlaintextPii.run(run_opts)

    print_exemptions(NoPlaintextPii.exemptions(findings))

    violations =
      findings
      |> NoPlaintextPii.violations()
      |> Enum.map(&Finding.format/1)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Run the CI-mode check and return the raw findings (violations + exempts),
  without halting. Separated from `run/1` so tests can call it directly.
  """
  @spec check(keyword()) :: [Finding.t()]
  def check(opts \\ []) do
    {:ok, findings} = NoPlaintextPii.run(opts)
    findings
  end

  # ---------------------------------------------------------------------------

  defp build_run_opts(opts) do
    repo_opt =
      case Keyword.get(opts, :repo) do
        nil -> []
        repo_str -> [repo: Module.concat([repo_str])]
      end

    domain_opt =
      case Keyword.get_values(opts, :domain) do
        [] -> []
        domain_strings -> [domains: Enum.map(domain_strings, &Module.concat([&1]))]
      end

    repo_opt ++ domain_opt
  end

  # The repo the tiers query. Mirrors Samen.Verifier.CatalogParity: the kernel's
  # test/host config sets `start_repo? = false` (test_helper owns the lifecycle),
  # so `app.start` alone does not start it. Start it here (idempotent) so the
  # DB-tier scans can run — otherwise every tier fails closed with "repo not
  # started", which is correct but useless as a green-path CI gate.
  defp ensure_repo_started!(run_opts) do
    repo = Keyword.get(run_opts, :repo) || configured_repo()

    if repo do
      case repo.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> Mix.raise("Could not start repo #{inspect(repo)}: #{inspect(reason)}")
      end
    else
      :ok
    end
  end

  defp configured_repo do
    Application.get_env(:samen_core, :verify_repo) ||
      Application.get_env(:samen_core, :non_pii_repo) ||
      Application.get_env(:samen_core, :reveal_grant_repo)
  end

  defp print_exemptions([]), do: :ok

  defp print_exemptions(exempts) do
    IO.puts("")

    IO.puts(
      "#{@task_name}: #{length(exempts)} registered non_pii! exemption(s) " <>
        "(plaintext-at-rest by design; NOT failures):"
    )

    Enum.each(exempts, fn e -> IO.puts("  · #{Finding.format(e)}") end)
  end
end
