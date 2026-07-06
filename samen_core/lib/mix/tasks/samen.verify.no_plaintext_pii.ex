defmodule Mix.Tasks.Samen.Verify.NoPlaintextPii do
  @shortdoc "The destruction oracle: CI-mode token-only invariant + post-shred --subject --tiers all."

  @moduledoc """
  `mix samen.verify.no_plaintext_pii` — verifier C5, **THE DESTRUCTION ORACLE**
  (plan §C; T1.8d CI mode + T2.9 post-shred mode). Doc §runs oracle block.

  Two modes, one task:

  ## CI mode (default — no `--subject`)

  Asserts the **token-only-downstream** invariant over every projected tier
  (vault declarations, audit rows, `aud_event`, rollups, catalog, log-telemetry
  config, trace/event sink schema). This is the build gate; it runs exactly as
  before.

      mix samen.verify.no_plaintext_pii
      mix samen.verify.no_plaintext_pii --repo MyApp.Repo
      mix samen.verify.no_plaintext_pii --domain MyApp.Crm

  ## Post-shred mode (`--subject <uuid> --tiers all`) — T2.9

  Run against an ERASED subject, this ORCHESTRATES THREE CHECKS to prove the
  erasure took (doc §runs oracle block):

    1. **DB-TIER CONTENT SCAN** — live·replica·cdc_mirror·rollup·audit·
       registered_non_pii: FAIL if any holds decryptable plaintext OR ciphertext
       that decrypts under a key other than the destroyed one.
    2. **BACKUP/PITR-HISTORY SCAN** — the subject key is absent from every DB tier
       + PITR history; the external store's PITR/backup is disabled.
    3. **KMS DESTRUCTION ATTESTATION** — a POSITIVE `:shredded` tombstone
       (`:absent` == FAIL); the wrapped DEK is actually gone.

  Plus the INGRESS-CLASS trace-sink schema assertion (token/bounded-ID/pseudonym-
  only; pseudonym unlinks on shred) and the inactive CDC-mirror STUB (Phase-6).

      mix samen.verify.no_plaintext_pii --subject 3f2a… --tiers all

  Options for post-shred mode:
    * `--subject <uuid>` — REQUIRED for post-shred mode.
    * `--tiers all` — the full roster (the only value the doc names). Any other
      value is refused (fail closed — a partial-tier run must be explicit and is
      not yet supported).
    * `--replica <Repo>` — the SIMULATED replica repo (a second DB restored from a
      live snapshot). `--replica none` states on the record there is no replica.
      Absent in a `--tiers all` run => the replica tier fails closed (silence is
      not an all-clear). No physical replica exists in this environment.
    * `--pitr <Repo>` (repeatable) — PITR-snapshot repos to scan (the pg_dump
      history from the T2.5 drill, restored into throwaway DBs). Absent => the
      live tier's key-absence assertion holds and the PITR-snapshot scan is a
      documented operator seam.

  ## Exit code (fail-closed)

  Exits 0 when there are no `:violation` findings, 1 otherwise (via
  `:erlang.halt/1`, so no cleanup hook can swallow the code). `:exempt` (registered
  `non_pii!`) and `:pass` (positive post-shred attestation) findings are LISTED but
  never affect the exit code.
  """

  use Mix.Task

  alias Samen.NoPlaintextPii
  alias Samen.NoPlaintextPii.Finding

  @task_name "samen.verify.no_plaintext_pii"

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(args,
        strict: [
          repo: :string,
          domain: [:string, :keep],
          subject: :string,
          tiers: :string,
          replica: :string,
          pitr: [:string, :keep]
        ]
      )

    Mix.Task.run("app.start")

    case Keyword.get(opts, :subject) do
      nil -> run_ci_mode(opts)
      subject -> run_post_shred_mode(subject, opts)
    end
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
  # CI mode
  # ---------------------------------------------------------------------------

  defp run_ci_mode(opts) do
    run_opts = build_ci_opts(opts)
    ensure_repo_started!(run_opts)
    {:ok, findings} = NoPlaintextPii.run(run_opts)

    print_exemptions(NoPlaintextPii.exemptions(findings))

    violations =
      findings
      |> NoPlaintextPii.violations()
      |> Enum.map(&Finding.format/1)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  # ---------------------------------------------------------------------------
  # Post-shred mode (T2.9)
  # ---------------------------------------------------------------------------

  defp run_post_shred_mode(subject, opts) do
    tiers_flag = Keyword.get(opts, :tiers)

    unless tiers_flag == "all" do
      Mix.raise(
        "#{@task_name} post-shred mode requires `--tiers all` (got #{inspect(tiers_flag)}). " <>
          "The destruction oracle runs the full tier roster; a partial-tier post-shred run " <>
          "is not supported (fail closed)."
      )
    end

    run_opts = build_post_shred_opts(subject, opts)
    ensure_repo_started!(run_opts)
    start_extra_repos!(run_opts)

    {:ok, findings} = NoPlaintextPii.run(run_opts)

    print_passes(NoPlaintextPii.passes(findings))
    print_exemptions(NoPlaintextPii.exemptions(findings))

    violations =
      findings
      |> NoPlaintextPii.violations()
      |> Enum.map(&Finding.format/1)

    IO.puts("")
    IO.puts("#{@task_name}: POST-SHRED ORACLE for subject #{subject} (--tiers all)")

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  # ---------------------------------------------------------------------------

  defp build_ci_opts(opts) do
    repo_opt(opts) ++ domain_opt(opts)
  end

  defp build_post_shred_opts(subject, opts) do
    base =
      repo_opt(opts) ++
        domain_opt(opts) ++
        [mode: :post_shred, subject_id: subject]

    base
    |> maybe_put_replica(opts)
    |> maybe_put_pitr(opts)
  end

  defp repo_opt(opts) do
    case Keyword.get(opts, :repo) do
      nil -> []
      repo_str -> [repo: Module.concat([repo_str])]
    end
  end

  defp domain_opt(opts) do
    case Keyword.get_values(opts, :domain) do
      [] -> []
      domain_strings -> [domains: Enum.map(domain_strings, &Module.concat([&1]))]
    end
  end

  defp maybe_put_replica(run_opts, opts) do
    case Keyword.get(opts, :replica) do
      nil -> run_opts
      "none" -> Keyword.put(run_opts, :replica, :none)
      repo_str -> Keyword.put(run_opts, :replica, Module.concat([repo_str]))
    end
  end

  defp maybe_put_pitr(run_opts, opts) do
    case Keyword.get_values(opts, :pitr) do
      [] -> run_opts
      pitr_strings -> Keyword.put(run_opts, :pitr_repos, Enum.map(pitr_strings, &Module.concat([&1])))
    end
  end

  # The repo the tiers query. Mirrors Samen.Verifier.CatalogParity: the kernel's
  # test/host config sets `start_repo? = false` (test_helper owns the lifecycle),
  # so `app.start` alone does not start it. Start it here (idempotent) so the
  # DB-tier scans can run — otherwise every tier fails closed with "repo not
  # started", which is correct but useless as a green-path CI gate.
  defp ensure_repo_started!(run_opts) do
    repo = Keyword.get(run_opts, :repo) || configured_repo()

    if repo, do: start_repo!(repo), else: :ok
  end

  # Post-shred mode may name replica / PITR-snapshot repos as bare module atoms.
  # Their Ecto config must be present (the operator wires them per deployment);
  # we start them idempotently so the scans can run. A repo whose config is
  # missing is a fail-closed operator error, surfaced clearly.
  defp start_extra_repos!(run_opts) do
    extras =
      [Keyword.get(run_opts, :replica) | List.wrap(Keyword.get(run_opts, :pitr_repos))]
      |> Enum.reject(&(&1 in [nil, :none]))

    Enum.each(extras, &start_repo!/1)
  end

  defp start_repo!(repo) do
    case repo.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("Could not start repo #{inspect(repo)}: #{inspect(reason)}")
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

  defp print_passes([]), do: :ok

  defp print_passes(passes) do
    IO.puts("")

    IO.puts(
      "#{@task_name}: #{length(passes)} positive post-shred attestation(s) " <>
        "(the erasure took — this is what you show an auditor):"
    )

    Enum.each(passes, fn p -> IO.puts("  ✓ #{Finding.format(p)}") end)
  end
end
