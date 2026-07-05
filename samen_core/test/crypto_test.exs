defmodule Samen.KmsCryptoTest do
  @moduledoc """
  Unit tests for `Samen.Kms.Crypto` — the envelope-crypto primitives (T1.4).

  Tests:
  - AES-256-GCM encrypt/decrypt round-trip.
  - Wrap/unwrap round-trip (DEK envelope).
  - Tampered ciphertext fails the GCM tag check and returns {:error, :decrypt_failed}
    (never garbage plaintext — fail-closed).
  - Wrong key fails the tag check.
  - Pseudonym derivation: same input → same output; different subjects → different;
    different DEKs → different; hex-encoded 64-char output.
  """
  use ExUnit.Case, async: true

  alias Samen.Kms.Crypto

  @master_key :crypto.strong_rand_bytes(32)

  describe "generate_dek/0" do
    test "generates 32 random bytes" do
      dek = Crypto.generate_dek()
      assert byte_size(dek) == 32
    end

    test "two DEKs are not equal (with overwhelming probability)" do
      refute Crypto.generate_dek() == Crypto.generate_dek()
    end
  end

  describe "wrap/unwrap round-trip" do
    test "unwrap recovers the original DEK" do
      dek = Crypto.generate_dek()
      wrapped = Crypto.wrap(@master_key, dek)
      assert {:ok, ^dek} = Crypto.unwrap(@master_key, wrapped)
    end

    test "wrong master key fails the tag check" do
      dek = Crypto.generate_dek()
      wrapped = Crypto.wrap(@master_key, dek)
      wrong_master = :crypto.strong_rand_bytes(32)
      assert {:error, :decrypt_failed} = Crypto.unwrap(wrong_master, wrapped)
    end

    test "tampered wrapped blob fails the tag check" do
      dek = Crypto.generate_dek()
      wrapped = Crypto.wrap(@master_key, dek)
      # Flip one byte in the ciphertext portion (after iv + tag).
      <<iv_tag::binary-size(28), rest::binary>> = wrapped
      tampered = iv_tag <> flip_byte(rest)
      assert {:error, :decrypt_failed} = Crypto.unwrap(@master_key, tampered)
    end
  end

  describe "encrypt/decrypt round-trip" do
    test "decrypt recovers the original plaintext" do
      dek = Crypto.generate_dek()
      plaintext = "test@example.com"
      blob = Crypto.encrypt(dek, plaintext)
      assert {:ok, ^plaintext} = Crypto.decrypt(dek, blob)
    end

    test "wrong key fails — never returns garbage plaintext (fail-closed)" do
      dek = Crypto.generate_dek()
      blob = Crypto.encrypt(dek, "secret@example.com")
      wrong_dek = Crypto.generate_dek()
      assert {:error, :decrypt_failed} = Crypto.decrypt(wrong_dek, blob)
    end

    test "tampered ciphertext fails the tag check" do
      dek = Crypto.generate_dek()
      blob = Crypto.encrypt(dek, "secret")
      # Flip a byte in the ciphertext portion.
      <<iv_tag::binary-size(28), rest::binary>> = blob
      tampered = iv_tag <> flip_byte(rest)
      assert {:error, :decrypt_failed} = Crypto.decrypt(dek, tampered)
    end

    test "encrypt produces unique blobs (random IV)" do
      dek = Crypto.generate_dek()
      blob1 = Crypto.encrypt(dek, "same plaintext")
      blob2 = Crypto.encrypt(dek, "same plaintext")
      refute blob1 == blob2
    end
  end

  describe "pseudonym/2" do
    setup do
      {:ok, dek: Crypto.generate_dek()}
    end

    test "same DEK + same subject_id → same pseudonym", %{dek: dek} do
      p1 = Crypto.pseudonym(dek, "subj-aaa")
      p2 = Crypto.pseudonym(dek, "subj-aaa")
      assert p1 == p2
    end

    test "same DEK + different subject_ids → different pseudonyms", %{dek: dek} do
      p1 = Crypto.pseudonym(dek, "subj-aaa")
      p2 = Crypto.pseudonym(dek, "subj-bbb")
      refute p1 == p2
    end

    test "different DEKs → different pseudonyms for same subject" do
      dek1 = Crypto.generate_dek()
      dek2 = Crypto.generate_dek()
      p1 = Crypto.pseudonym(dek1, "subj-aaa")
      p2 = Crypto.pseudonym(dek2, "subj-aaa")
      refute p1 == p2
    end

    test "pseudonym is 64-char lowercase hex", %{dek: dek} do
      p = Crypto.pseudonym(dek, "subj-aaa")
      assert String.length(p) == 64
      assert p =~ ~r/\A[0-9a-f]+\z/
    end
  end

  # Flip the first byte to produce a tampered blob.
  defp flip_byte(<<b, rest::binary>>), do: <<Bitwise.bxor(b, 0xFF), rest::binary>>
  defp flip_byte(<<>>), do: <<0xFF>>
end
