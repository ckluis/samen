defmodule Samen.OutageTest do
  @moduledoc """
  RED PATH — RQ4 fail-closed, deny-recoverable (ADR-001 §6, §8.2 red path 5).

  With the key store made unreachable, decrypt/reveal MUST deny (`:unavailable`)
  and MUST NOT fall back to any cached or local plaintext key. The failure mode
  is *unavailability*, not *disclosure*.
  """
  use ExUnit.Case, async: false

  alias Samen.Vault

  @secret "frank.outage@example.com"

  setup do
    S05Vault.DBCase.truncate!()
    Application.put_env(:s05_vault, :kms_adapter, Samen.Kms.FileBacked)
    Samen.Kms.FileBacked.simulate_outage(false)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
    :ok
  end

  test "key-store outage denies reveal with :unavailable, never plaintext" do
    subject = "subj-outage-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
    {:ok, person} = Vault.store_email(subject, "Frank", @secret)

    # Works while the store is reachable.
    assert {:ok, @secret} = Vault.reveal(person.email)

    # Simulate the store/KMS being unreachable.
    Samen.Kms.FileBacked.simulate_outage(true)

    # RED PATH: must deny, never return plaintext.
    assert {:error, :unavailable} = Vault.reveal(person.email)
    assert {:error, :unavailable} = Samen.Kms.FileBacked.unwrap(subject)

    # Deny-RECOVERABLE: healing the store restores decryptability (the key was
    # never destroyed, only unreachable).
    Samen.Kms.FileBacked.simulate_outage(false)
    assert {:ok, @secret} = Vault.reveal(person.email)
  end

  test "outage does not leak via any local cache (no plaintext fallback exists)" do
    subject = "subj-nocache-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())
    {:ok, person} = Vault.store_email(subject, "Frank", @secret)
    assert {:ok, @secret} = Vault.reveal(person.email)

    Samen.Kms.FileBacked.simulate_outage(true)
    # Even immediately after a successful decrypt, a subsequent decrypt during
    # outage denies — there is no persisted plaintext-key cache by construction.
    assert {:error, :unavailable} = Vault.reveal(person.email)
  end
end
