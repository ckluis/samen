defmodule Samen.NoPlaintextPii.Tiers.PostShred.KmsAttestation do
  @moduledoc """
  **Post-shred check (3): the KMS DESTRUCTION ATTESTATION** (doc §runs oracle block,
  check 3; ADR-001 §5; plan T2.9).

  > (3) KMS DESTRUCTION ATTESTATION — the oracle QUERIES the KMS and checks it
  >     reports the subject key destroyed. This is an ATTESTATION it reads, NOT a
  >     destruction the oracle itself proves — the KMS is the system of record for
  >     key state.

  This tier reads the KMS/key-store as the **system of record**. It does NOT try to
  decrypt-and-fail as a proof of destruction (that would be a weaker, circumstantial
  argument); it reads the store's own attestation via `Samen.Vault.attest/1`
  (`Samen.Kms.attest/1`), and it REQUIRES a positive `:shredded` tombstone:

    * `:shredded` with a `destroyed_at` → **PASS** (ADR-001 §5).
    * `:absent`  → **FAIL** — a positive tombstone is required, not mere absence, so
      "the row was silently dropped" cannot masquerade as "the key was destroyed"
      (ADR-001 §5, red path 3).
    * `:active`  → **FAIL** — the key still exists (the shred did not run).

  ## Defence in depth (ADR-001 §8.2, Gate-0 P2 shred fix)

  A tombstone written while the wrapped DEK survives is NOT a real erasure. So the
  tier also asserts `key_material_present?/1 == false` — the wrapped DEK is actually
  gone, not merely tombstoned. Both must hold.

  ## `backups_disabled?` (ADR-001 CI check 2)

  ADR-001 §5 has the oracle ALSO assert the store's PITR/backup is disabled here.
  The BackupPitr tier (check 2) owns the primary assertion; this tier repeats it as
  a cross-check tied to the attestation (the attestation and the backup posture are
  the same store's guarantees), so a store that attests destruction but has PITR on
  still fails.

  ## Positive attestation

  `:post_shred` tier: emits a `:pass` when the tombstone is positive and the key
  material is gone; `:violation` on `:absent` / `:active` / surviving key material /
  attestation error / PITR-on. Never empty.
  """

  @behaviour Samen.NoPlaintextPii.Tier

  alias Samen.NoPlaintextPii.{Context, Finding}
  alias Samen.{Vault, Kms}

  @tier :kms_attestation

  @impl true
  def tier_name, do: @tier

  @impl true
  def mode, do: :post_shred

  @impl true
  def describe,
    do:
      "post-shred KMS destruction attestation: a POSITIVE :shredded tombstone " <>
        "(:absent/:active == FAIL) + wrapped DEK actually gone + store backups disabled"

  @impl true
  def check(%Context{subject_id: nil}) do
    [
      Finding.violation(
        @tier,
        "<subject>",
        "post-shred KMS attestation requires --subject <uuid> — fail closed."
      )
    ]
  end

  def check(%Context{subject_id: sid}) do
    attestation_findings(sid) ++ key_material_findings(sid) ++ backups_findings(sid)
  end

  # ---------------------------------------------------------------------------

  defp attestation_findings(sid) do
    case Vault.attest(sid) do
      {:ok, %{state: :shredded, destroyed_at: destroyed_at} = att} when not is_nil(destroyed_at) ->
        [
          Finding.pass(
            @tier,
            sid,
            "KMS attests a POSITIVE :shredded tombstone (destroyed_at=#{inspect(destroyed_at)}, " <>
              "attestation_id=#{att[:attestation_id] || "none"}) — the system of record " <>
              "reports the key destroyed"
          )
        ]

      {:ok, %{state: :shredded, destroyed_at: nil}} ->
        [
          Finding.violation(
            @tier,
            sid,
            "KMS reports :shredded but with NO destroyed_at timestamp — an incomplete " <>
              "tombstone is not a positive attestation. Fail closed."
          )
        ]

      {:ok, %{state: :absent}} ->
        [
          Finding.violation(
            @tier,
            sid,
            ":absent == FAIL. A POSITIVE tombstone is required, not mere absence — a silently " <>
              "dropped key row must NOT masquerade as a destroyed key (ADR-001 §5 red path 3)."
          )
        ]

      {:ok, %{state: :active}} ->
        [
          Finding.violation(
            @tier,
            sid,
            ":active == FAIL. The subject key still EXISTS in the store — the crypto-shred " <>
              "did not run. Fail closed."
          )
        ]

      {:ok, %{state: other}} ->
        [
          Finding.violation(
            @tier,
            sid,
            "unexpected KMS key state #{inspect(other)} — only a positive :shredded " <>
              "tombstone passes. Fail closed."
          )
        ]

      {:error, reason} ->
        [
          Finding.violation(
            @tier,
            sid,
            "KMS attestation query failed (#{inspect(reason)}) — the oracle reads the store " <>
              "as system of record; an unreachable store is a fail-closed gap, never a pass."
          )
        ]
    end
  end

  defp key_material_findings(sid) do
    if Kms.adapter().key_material_present?(sid) do
      [
        Finding.violation(
          @tier,
          sid,
          "the wrapped DEK is STILL PRESENT in the store — a tombstone written over a " <>
            "surviving key is a FALSE attestation (the key is recoverable). Fail closed " <>
            "(ADR-001 §8.2 shred defence-in-depth)."
        )
      ]
    else
      [
        Finding.pass(
          @tier,
          sid,
          "the wrapped DEK is actually GONE from the store (key_material_present? == false) " <>
            "— defence-in-depth over the tombstone holds"
        )
      ]
    end
  end

  defp backups_findings(sid) do
    if Vault.backups_disabled?() do
      [
        Finding.pass(
          @tier,
          "#{sid}/store_backups",
          "the attesting store has PITR/continuous-backup DISABLED (ADR-001 CI check 2)"
        )
      ]
    else
      [
        Finding.violation(
          @tier,
          "#{sid}/store_backups",
          "the store attests destruction but has PITR/backup ENABLED — a restore could " <>
            "resurrect the key. Fail closed (ADR-001 CI check 2)."
        )
      ]
    end
  end
end
