defmodule Samen.NoPlaintextPii do
  @moduledoc """
  The `no_plaintext_pii` verifier core — **CI mode** (verifier C5; T1.8d).

  Asserts the **token-only-downstream** invariant over every projected tier that
  exists so far. The full post-shred destruction oracle
  (`--subject <uuid> --tiers all`, doc §runs oracle block) is Phase 2 (T2.9) — this
  module is its CI-mode foundation and, critically, its **extensible tier
  registry**: T2.9 adds `cdc_mirror` / `rollup` / `trace_sink` tiers by writing a
  `Samen.NoPlaintextPii.Tier` module and registering it, without touching this
  harness.

  ## What CI mode asserts (over the tiers that exist NOW)

    * **(a)** every vault-routed declaration's storage column is the token type
      (`Samen.NoPlaintextPii.Tiers.VaultDeclarations`);
    * **(b)** the projected audit-row surfaces (T1.6/T1.7 reveal/erasure rows) and
      the catalog itself expose only bounded-ID / token / enum / metadata columns
      (`Samen.NoPlaintextPii.Tiers.AuditRows`, `…Tiers.Catalog`);
    * **(c)** `db_statement` is disabled if `opentelemetry_ecto` is present
      (`Samen.NoPlaintextPii.Tiers.LogTelemetry`);
    * **(d)** registered `non_pii!` columns are **exempt-but-listed** (plaintext-at-
      rest by design) — emitted as `:exempt` findings, listed in output, never
      failing the build.

  ## The tier registry (extensibility for T2.9)

  `default_tiers/0` is the CI-mode roster. `run/1` accepts a `:tiers` override so
  the Phase-2 oracle (and tests) can drive an arbitrary tier set. A tier declares
  `mode/0` — `run/1` executes only `:ci` tiers (a `:post_shred` tier registered
  today is inert until T2.9 drives it with a subject). This is the seam the plan
  asks for: "Design the tier registry EXTENSIBLY (a behaviour/registry the Phase-2
  oracle adds cdc_mirror/rollup/trace_sink tiers to)."

  ## Fail-closed

  A tier that cannot introspect its surface returns a `:violation` finding (not a
  silent pass). `run/1` returns `{:ok, findings}`; the caller separates `:violation`
  from `:exempt` and halts non-zero iff any `:violation` exists.
  """

  alias Samen.NoPlaintextPii.{Context, Finding}

  alias Samen.NoPlaintextPii.Tiers.{
    VaultDeclarations,
    AuditRows,
    AudEvent,
    Rollup,
    Catalog,
    LogTelemetry,
    TraceSink,
    ObanJobs
  }

  # T4.3: the hash-chain audit tier. Aliased under a distinct name to avoid colliding
  # with the top-level `Samen.AuditChain` runtime module.
  alias Samen.NoPlaintextPii.Tiers.AuditChain, as: AuditChainTier

  alias Samen.NoPlaintextPii.Tiers.PostShred

  @doc """
  The default CI-mode tier roster.

  T2.2 adds `AudEvent` (the append-only event/audit tier).
  Phase-2 T2.9 appends `cdc_mirror` / `rollup` / `trace_sink` tier modules here
  (or passes them via `run(tiers: …)`).
  T3.13 / F2.1 adds `ObanJobs` — the `oban_jobs` token-only-args convention tier.
  T4.3 adds `AuditChain` — the `aud_chain` hash-chain token-only tier.
  """
  @spec default_tiers() :: [module()]
  def default_tiers,
    do: [
      VaultDeclarations,
      AuditRows,
      AudEvent,
      Rollup,
      Catalog,
      LogTelemetry,
      TraceSink,
      ObanJobs,
      AuditChainTier
    ]

  @doc """
  The **post-shred** tier roster (T2.9 — `--subject <uuid> --tiers all`).

  The doc's three orchestrated checks, plus the ingress-class trace-sink assertion
  and the inactive CDC-mirror stub:

    * `PostShred.DbContent`        — check (1): DB-tier content scan
      (live·replica·rollup·audit·registered_non_pii; wrong-key probe).
    * `PostShred.BackupPitr`       — check (2): backup/PITR-history scan
      (key absent from every DB tier + PITR history; store backups disabled).
    * `PostShred.KmsAttestation`   — check (3): positive `:shredded` tombstone
      (`:absent` == FAIL) + wrapped DEK gone + store backups disabled.
    * `PostShred.TraceSinkIngress` — ingress-class trace-sink schema assertion +
      pseudonym-unlinks-on-shred (NOT a content scan).
    * `PostShred.CdcMirror`        — STUB (inactive until Phase-6 H4 / T6.5).

  These are `:post_shred`-mode tiers: inert in CI mode, driven only by a `run/1`
  with `mode: :post_shred` and a `:subject_id`.
  """
  @spec post_shred_tiers() :: [module()]
  def post_shred_tiers,
    do: [
      PostShred.DbContent,
      PostShred.BackupPitr,
      PostShred.KmsAttestation,
      PostShred.TraceSinkIngress,
      PostShred.CdcMirror
    ]

  @doc """
  Run the oracle and return every finding (violations + exempts + passes).

  Options:
    * `:mode` — `:ci` (default) runs only `:ci` tiers (the token-only-downstream
      invariant). `:post_shred` runs the T2.9 destruction oracle's three checks
      against a `:subject_id`.
    * `:tiers` — override the tier roster (tests / custom rosters). Defaults to
      `default_tiers/0` for `:ci` and `post_shred_tiers/0` for `:post_shred`.
    * everything else is forwarded to `Samen.NoPlaintextPii.Context.build/1`
      (`:repo`, `:resources`, `:domains`, `:deps`, `:non_pii_entries`,
      and — post-shred — `:subject_id`, `:replica`, `:pitr_repos`).

  Returns `{:ok, [Finding.t()]}`.
  """
  @spec run(keyword()) :: {:ok, [Finding.t()]}
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :ci)
    tiers = Keyword.get(opts, :tiers, default_roster(mode))

    context =
      opts
      |> Keyword.drop([:tiers, :mode])
      |> Context.build()

    findings =
      tiers
      |> Enum.filter(fn tier -> tier.mode() == mode end)
      |> Enum.flat_map(fn tier -> run_tier(tier, context) end)

    {:ok, findings}
  end

  defp default_roster(:post_shred), do: post_shred_tiers()
  defp default_roster(_), do: default_tiers()

  @doc """
  The subset of findings that FAIL the build (`:violation`). `:exempt` and `:pass`
  findings are excluded — they are listed, not failed.
  """
  @spec violations([Finding.t()]) :: [Finding.t()]
  def violations(findings), do: Enum.filter(findings, &(&1.severity == :violation))

  @doc "The `:exempt` findings (listed in output, do not fail the build)."
  @spec exemptions([Finding.t()]) :: [Finding.t()]
  def exemptions(findings), do: Enum.filter(findings, &(&1.severity == :exempt))

  @doc "The `:pass` findings — positive post-shred attestations (listed, never fail)."
  @spec passes([Finding.t()]) :: [Finding.t()]
  def passes(findings), do: Enum.filter(findings, &(&1.severity == :pass))

  # ---------------------------------------------------------------------------

  # A tier that itself raises is a fail-closed violation (never a silent skip).
  defp run_tier(tier, context) do
    tier.check(context)
  rescue
    e ->
      [
        Finding.violation(
          safe_name(tier),
          "<tier-crash>",
          "tier raised #{inspect(e.__struct__)}: #{Exception.message(e)} — fail closed."
        )
      ]
  end

  defp safe_name(tier) do
    tier.tier_name()
  rescue
    _ -> :unknown_tier
  end
end
