defmodule Samen.Kms.AwsKmsDynamo do
  @moduledoc """
  Production `Samen.Kms` adapter skeleton — AWS KMS + DynamoDB with PITR off
  (ADR-001 §8.1, Candidate A; T1.4 scope).

  ## Status: SKELETON

  This module compiles and passes the conformance-suite shape — it implements
  every callback in `Samen.Kms` — but **all network calls are guarded behind a
  config flag** and are NOT exercised in CI (no AWS account is required). The
  guard is `Application.get_env(:samen_core, :aws_kms_dynamo_enabled, false)`.

  When the flag is `false` (the default, and always in CI), every callback
  returns a documented stub response. When the flag is `true`, the adapter
  is expected to call AWS KMS + DynamoDB; that path is left as a `TODO` stub
  that raises a clear error rather than silently misbehaving.

  ## Production wiring plan (not yet implemented)

  The production path would use:
    - `ex_aws` + `ex_aws_kms` for KMS.Encrypt / KMS.Decrypt
    - `ex_aws_dynamo` for the wrapped-DEK DynamoDB table
    - The DynamoDB table `samen_wrapped_deks` with:
        * PITR DISABLED (the load-bearing config — load-bearing for RQ1)
        * IAM Deny on CreateBackup / ExportTableToPointInTime / UpdateContinuousBackups
        * Schema: PK = subject_id; attributes: wrapped_dek, state, created_at, destroyed_at,
          attestation_id, km_version

  ## Conformance suite

  When `aws_kms_dynamo_enabled: false`, the adapter behaves as an in-memory stub
  so the conformance suite can be run against it without a live AWS account.
  The stub delegates to `Samen.Kms.InMemory` under the hood for that purpose.

  ## ADR-001 §8.2 obligations for this adapter (when enabled)

  1. PITR cannot resurrect the key — the DynamoDB table has PITR disabled; a
     `DescribeContinuousBackups` call asserting `DISABLED` must pass the oracle's
     check-2.
  2. Post-shred decrypt raises `:shredded` — `unwrap/1` after `shred/1`.
  3. Attestation is positive, not mere absence — `attest/1` returns `state: :shredded`
     with a `destroyed_at`; `:absent` is FAIL for post-shred oracle assertion.
  4. Pseudonym unlinks on shred — `pseudonym/2` raises `:shredded` after `shred/1`.
  5. KMS/store outage fails closed — `unwrap/1` returns `:unavailable`, never plaintext.
  6. `backups_disabled?/0` returns `false` when PITR is on — oracle check-2 exits 1.
  7. `key_material_present?/1` returns `false` after shred — the wrapped-DEK item
     is actually DELETED from DynamoDB (a `GetItem` returns no item), not merely
     tombstoned. The oracle's check-2b asserts this so a tombstone-written-but-DEK-
     left "shred" fails closed (Gate-0 vault-stack fix, P2 shred defence-in-depth).
     Production: `shred/1` must `DeleteItem` the wrapped DEK and then confirm via
     `GetItem` that it is gone BEFORE writing the positive tombstone.

  None of these are verified in CI for this skeleton. They are stated here as the
  acceptance criteria for when `aws_kms_dynamo_enabled: true` is wired in production.
  """

  @behaviour Samen.Kms

  # Stub delegation to InMemory for the disabled-mode conformance suite.
  # When enabled: replace these with real AWS SDK calls.
  alias Samen.Kms.InMemory

  @doc false
  defp enabled? do
    Application.get_env(:samen_core, :aws_kms_dynamo_enabled, false)
  end

  defp stub_delegate(fun, args) when is_atom(fun) do
    if enabled?() do
      raise """
      Samen.Kms.AwsKmsDynamo: aws_kms_dynamo_enabled is true but the real AWS
      implementation is not yet wired. Replace the stub in #{__MODULE__}.#{fun}/#{length(args)}
      with actual ex_aws_kms / ex_aws_dynamo calls (ADR-001 Candidate A, T1.4).
      """
    else
      apply(InMemory, fun, args)
    end
  end

  @impl true
  def generate_subject_key(subject_id) do
    stub_delegate(:generate_subject_key, [subject_id])
  end

  @impl true
  def unwrap(subject_id) do
    stub_delegate(:unwrap, [subject_id])
  end

  @impl true
  def shred(subject_id) do
    stub_delegate(:shred, [subject_id])
  end

  @impl true
  def attest(subject_id) do
    stub_delegate(:attest, [subject_id])
  end

  @impl true
  def backups_disabled? do
    if enabled?() do
      # TODO: call DescribeContinuousBackups on the samen_wrapped_deks table.
      # Return false if PITR is accidentally enabled (oracle check-2 will fail
      # the build, which is the correct behavior — a misconfiguration silently
      # breaks RQ1 per ADR-001 §8 consequences).
      raise """
      Samen.Kms.AwsKmsDynamo: backups_disabled?/0 — real DescribeContinuousBackups
      call not yet wired. Implement with ex_aws_dynamo (ADR-001 §8.1, oracle check-2).
      """
    else
      # Stub: the disabled-mode InMemory store has no backup facility by construction.
      true
    end
  end

  @impl true
  def key_material_present?(subject_id) do
    if enabled?() do
      # TODO: GetItem on the samen_wrapped_deks table for subject_id; return true
      # iff the wrapped-DEK item still exists. Post-shred this MUST be false —
      # DeleteItem must have removed the item (oracle check-2b / P2 defence-in-depth).
      raise """
      Samen.Kms.AwsKmsDynamo: key_material_present?/1 — real GetItem call not yet
      wired. Implement with ex_aws_dynamo (Gate-0 vault-stack P2 shred fix).
      """
    else
      InMemory.key_material_present?(subject_id)
    end
  end

  @impl true
  def pseudonym(subject_id, target_subject_id) do
    stub_delegate(:pseudonym, [subject_id, target_subject_id])
  end
end
