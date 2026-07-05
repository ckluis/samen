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
    LogTelemetry
  }

  @doc """
  The default CI-mode tier roster.

  T2.2 adds `AudEvent` (the append-only event/audit tier).
  Phase-2 T2.9 appends `cdc_mirror` / `rollup` / `trace_sink` tier modules here
  (or passes them via `run(tiers: …)`).
  """
  @spec default_tiers() :: [module()]
  def default_tiers, do: [VaultDeclarations, AuditRows, AudEvent, Catalog, LogTelemetry]

  @doc """
  Run the CI-mode invariant and return every finding (violations + exempts).

  Options:
    * `:tiers` — override the tier roster (T2.9 / tests). Defaults to
      `default_tiers/0`.
    * `:mode` — `:ci` (default) runs only `:ci` tiers. (`:post_shred` is the T2.9
      hook; no post-shred tiers ship in this task.)
    * everything else is forwarded to `Samen.NoPlaintextPii.Context.build/1`
      (`:repo`, `:resources`, `:domains`, `:deps`, `:non_pii_entries`).

  Returns `{:ok, [Finding.t()]}`.
  """
  @spec run(keyword()) :: {:ok, [Finding.t()]}
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :ci)
    tiers = Keyword.get(opts, :tiers, default_tiers())

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

  @doc """
  The subset of findings that FAIL the build (`:violation`). `:exempt` findings
  are excluded — they are listed, not failed (clause (d)).
  """
  @spec violations([Finding.t()]) :: [Finding.t()]
  def violations(findings), do: Enum.filter(findings, &(&1.severity == :violation))

  @doc "The `:exempt` findings (listed in output, do not fail the build)."
  @spec exemptions([Finding.t()]) :: [Finding.t()]
  def exemptions(findings), do: Enum.filter(findings, &(&1.severity == :exempt))

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
