defmodule Samen.CryptoShredTest do
  @moduledoc """
  RED PATH (a): post-shred decrypt raises/denies (ADR-001 §8.2 red path 2).
  Plus: attestation is positive not mere absence (red path 3), and the J2
  pseudonym unlinks on shred (red path 4, RQ5).

  These run against BOTH KMS adapters via a parametrized helper, because the
  guarantee must hold for whichever store backs the runtime.
  """
  use ExUnit.Case, async: false

  alias Samen.Vault

  @secret "carol.pii@example.com"

  setup do
    S05Vault.DBCase.truncate!()
    Samen.Kms.FileBacked.simulate_outage(false)
    :ok
  end

  # --- FileBacked adapter (the configured default) ---

  describe "FileBacked adapter" do
    setup do
      Application.put_env(:s05_vault, :kms_adapter, Samen.Kms.FileBacked)
      :ok
    end

    test "post-shred: reveal denies with :shredded, never plaintext" do
      subject = subj()
      {:ok, person} = Vault.store_email(subject, "Carol", @secret)
      assert {:ok, @secret} = Vault.reveal(person.email)

      {:ok, att} = Vault.shred(subject)
      assert att.state == :shredded

      # RED PATH: this MUST NOT return {:ok, plaintext}.
      assert {:error, :shredded} = Vault.reveal(person.email)
    end

    test "post-shred: raw KMS unwrap denies with :shredded" do
      subject = subj()
      {:ok, _person} = Vault.store_email(subject, "Carol", @secret)
      {:ok, _} = Vault.shred(subject)
      assert {:error, :shredded} = Samen.Kms.FileBacked.unwrap(subject)
    end

    test "post-shred: oracle-style scan finds no decryptable bytes" do
      subject = subj()
      {:ok, _person} = Vault.store_email(subject, "Carol", @secret)
      # Store a second email row for the same subject to prove ALL of the
      # subject's ciphertext dies at once.
      {:ok, _person2} = Vault.store_email(subject, "Carol2", "carol2@example.com")

      {:ok, _} = Vault.shred(subject)
      assert {:ok, :no_plaintext} = Vault.scan_no_plaintext(subject)
    end

    test "attestation is positive (:shredded + destroyed_at), not mere absence" do
      subject = subj()
      {:ok, _person} = Vault.store_email(subject, "Carol", @secret)
      {:ok, _} = Vault.shred(subject)

      {:ok, att} = Vault.attest(subject)
      assert att.state == :shredded
      assert att.destroyed_at != nil
      assert is_binary(att.attestation_id)
    end

    test "attest of a never-seen subject is :absent (oracle treats as FAIL for post-shred)" do
      {:ok, att} = Vault.attest("subj-never-existed")
      assert att.state == :absent
      assert att.destroyed_at == nil
    end

    test "pseudonym unlinks on shred (RQ5): recompute fails :shredded" do
      subject = subj()
      {:ok, _person} = Vault.store_email(subject, "Carol", @secret)

      {:ok, pre} = Vault.pseudonym(subject)
      assert is_binary(pre) and byte_size(pre) == 64

      {:ok, _} = Vault.shred(subject)

      # RED PATH: after shred, the pseudonym key is unreconstructable.
      assert {:error, :shredded} = Vault.pseudonym(subject)
    end
  end

  # --- InMemory adapter (same guarantees) ---

  describe "InMemory adapter" do
    setup do
      Application.put_env(:s05_vault, :kms_adapter, Samen.Kms.InMemory)
      # Fresh InMemory agent state (it is supervised, so wait for the restart).
      if pid = Process.whereis(Samen.Kms.InMemory) do
        ref = Process.monitor(pid)
        Agent.stop(pid)
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1000 -> :ok
        end
      end

      wait_for_inmemory()
      on_exit(fn -> Application.put_env(:s05_vault, :kms_adapter, Samen.Kms.FileBacked) end)
      :ok
    end

    test "post-shred: reveal denies with :shredded, never plaintext" do
      subject = subj()
      {:ok, person} = Vault.store_email(subject, "Carol", @secret)
      assert {:ok, @secret} = Vault.reveal(person.email)

      {:ok, att} = Vault.shred(subject)
      assert att.state == :shredded
      assert {:error, :shredded} = Vault.reveal(person.email)
    end

    test "post-shred unwrap denies; attestation positive; pseudonym unlinks" do
      subject = subj()
      {:ok, _person} = Vault.store_email(subject, "Carol", @secret)
      {:ok, _pre} = Vault.pseudonym(subject)

      {:ok, _} = Vault.shred(subject)

      assert {:error, :shredded} = Samen.Kms.InMemory.unwrap(subject)
      assert {:ok, %{state: :shredded, destroyed_at: dt}} = Vault.attest(subject)
      assert dt != nil
      assert {:error, :shredded} = Vault.pseudonym(subject)
    end
  end

  defp subj, do: "subj-shred-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16())

  # The supervisor restarts InMemory after we stop it; poll until it's back.
  defp wait_for_inmemory(retries \\ 50)
  defp wait_for_inmemory(0), do: {:ok, _} = Samen.Kms.InMemory.start_link()

  defp wait_for_inmemory(n) do
    case Process.whereis(Samen.Kms.InMemory) do
      nil ->
        Process.sleep(10)
        wait_for_inmemory(n - 1)

      _pid ->
        :ok
    end
  end
end
