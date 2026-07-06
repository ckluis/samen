defmodule Samen.NoPlaintextPii.Tiers.PostShred.CdcMirror do
  @moduledoc """
  **Post-shred CDC-mirror tier — STUB (inactive, Phase-6 H4)** (doc §runs oracle
  block "live·replica·cdc_mirror·rollup·audit·registered_non_pii"; plan T2.9 "CDC
  tier stubbed until H4"; plan T6.5).

  The ClickHouse CDC mirror (ClickPipes/PeerDB) is a Phase-6 power-up, explicitly
  "a power-up, not a prerequisite" (§data). It mirrors token-blind rows, so it
  inherits erasure for free (the same token-only ciphertext key-shred already
  covers). Until it is wired (T6.5), there is no CDC mirror to scan.

  This tier is REGISTERED in the post-shred roster so the tier map matches the
  doc's tier list, but it is INACTIVE: it emits a single `:pass` finding stating
  the CDC mirror is not enabled in this deployment, with the operator-TODO seam.
  When H4 lands, this stub becomes a real content scan (the same shape as
  `PostShred.DbContent`'s live/replica scans, against the second `ecto_ch` repo)
  and a `never-read-current` lint.

  Configuration seam: a host enables the CDC mirror by wiring an `ecto_ch` repo and
  flipping `config :samen_core, :cdc_mirror_repo, MyApp.ClickHouseRepo`. This stub
  checks for that config and, if PRESENT, fails closed (an enabled CDC mirror MUST
  be scanned — a configured-but-unscanned mirror is a gap, not a pass) with a
  pointer to T6.5.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}

  @tier :cdc_mirror

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :post_shred

  @impl true
  def describe,
    do: "post-shred CDC-mirror tier — STUB (inactive until Phase-6 H4 / T6.5)"

  @impl true
  def check(%Context{subject_id: nil}) do
    [
      Finding.violation(
        @tier,
        "<subject>",
        "post-shred CDC-mirror tier requires --subject <uuid> — fail closed."
      )
    ]
  end

  def check(%Context{}) do
    case Application.get_env(:samen_core, :cdc_mirror_repo) do
      nil ->
        [
          Finding.pass(
            @tier,
            "cdc_mirror",
            "CDC mirror not enabled in this deployment (Phase-6 H4 power-up). STUB — the " <>
              "mirror carries token-blind rows and inherits erasure for free; a real content " <>
              "scan + never-read-current lint lands with T6.5 (operator TODO)."
          )
        ]

      repo ->
        [
          Finding.violation(
            @tier,
            "cdc_mirror",
            "a CDC-mirror repo is configured (#{inspect(repo)}) but the T2.9 stub cannot " <>
              "scan it — the CDC content scan is Phase-6 (T6.5). A configured-but-unscanned " <>
              "mirror is a fail-closed GAP, not a pass. Land T6.5 or unset :cdc_mirror_repo."
          )
        ]
    end
  end
end
