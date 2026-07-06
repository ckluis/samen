defmodule Samen.WideEventPseudonymTest do
  @moduledoc """
  T2.7 (c) — `actor_id` is a per-subject-keyed pseudonym `HMAC(psk_S, subject_id)`
  with `psk_S = HKDF(DEK_S, "samen/obs-pseudonym/v1")` (ADR-001 §2 RQ5; doc §runs 4b).

  This ports the T1.7 pseudonym-unlink red path UP to the wide-event layer: the
  actor_id a wide event carries is computed via `Samen.WideEvent.for_subject/2`
  (which calls the configured `Samen.Kms` adapter's `pseudonym/2`). Post-shred the
  DEK is gone, so the pseudonym is UNRECONSTRUCTABLE — the trace sink's actor_id
  becomes permanently unlinkable to the subject. That unlink IS the guarantee (the
  sink is ingress-class, not destruction-class — key-shred cannot reach the
  third-party backend, so the pseudonym must go dark on its own).
  """
  use ExUnit.Case, async: false

  alias Samen.WideEvent
  alias Samen.Erasure
  alias Samen.Vault

  setup do
    # Erasure.shred/2 seals DB tiers (audit + report), so a repo checkout is
    # needed even though the pseudonym itself is a pure KMS-adapter capability.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(SamenCore.TestRepo)
    prev = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.InMemory)

    on_exit(fn ->
      if prev, do: Application.put_env(:samen_core, :kms_adapter, prev)
    end)

    :ok
  end

  defp subj, do: "wide-event-subject-#{System.unique_integer([:positive])}"

  # Give the subject a DEK so the pseudonym is computable (store a vault field to
  # trigger generate_subject_key; the pseudonym rides that same DEK).
  defp seed(subject_id) do
    # generate_subject_key is idempotent-ish; storing a field ensures a DEK exists.
    Samen.Kms.InMemory.generate_subject_key(subject_id)
    :ok
  end

  test "for_subject computes a stable, opaque, non-PII actor_id pre-shred" do
    subject_id = subj()
    seed(subject_id)

    assert {:ok, actor_id} = WideEvent.for_subject(subject_id)
    assert {:ok, ^actor_id} = WideEvent.for_subject(subject_id), "pseudonym must be stable"
    assert is_binary(actor_id)
    # actor_id is a hex HMAC — opaque, whitespace-free, contains no subject id.
    refute String.contains?(actor_id, subject_id)
    refute String.contains?(actor_id, " ")

    # It fits the :token schema shape, so it can populate the actor_id field.
    assert {:ok, ev} = WideEvent.new(action: :req, actor_id: actor_id, row_count: 1)
    assert ev.actor_id == actor_id
  end

  test "actor_id matches Vault.pseudonym/1 (same DEK, same derivation)" do
    subject_id = subj()
    seed(subject_id)

    assert {:ok, from_wide} = WideEvent.for_subject(subject_id)
    assert {:ok, from_vault} = Vault.pseudonym(subject_id)
    assert from_wide == from_vault, "wide-event actor_id must be the SAME keyed pseudonym"
  end

  test "RED PATH: post-shred the actor_id is UNLINKABLE (key gone, recompute impossible)" do
    subject_id = subj()
    seed(subject_id)

    # Pre-shred: computable.
    assert {:ok, _actor_id} = WideEvent.for_subject(subject_id)

    # Destroy the subject's DEK.
    assert {:ok, _} = Erasure.shred(subject_id)

    # Post-shred: the pseudonym cannot be recomputed — the DEK it is keyed on is
    # gone. A wide event emitted now simply has no actor_id linkage.
    assert {:error, reason} = WideEvent.for_subject(subject_id)
    assert reason in [:shredded, :unavailable]
  end

  test "the pseudonym is derived from the DEK, so a DIFFERENT subject gets a different actor_id" do
    a = subj()
    b = subj()
    seed(a)
    seed(b)

    assert {:ok, pa} = WideEvent.for_subject(a)
    assert {:ok, pb} = WideEvent.for_subject(b)
    refute pa == pb, "distinct subjects must get distinct pseudonyms"
  end
end
