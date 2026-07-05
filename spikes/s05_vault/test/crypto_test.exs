defmodule Samen.CryptoTest do
  @moduledoc """
  Unit tests for the envelope-crypto primitives (ADR-001 §2). Includes red
  paths: wrong-key decrypt and tampered-ciphertext decrypt both fail closed
  (GCM tag check), never returning garbage plaintext.
  """
  use ExUnit.Case, async: true
  import Bitwise

  alias Samen.Kms.Crypto

  test "encrypt/decrypt round-trips exactly under the DEK" do
    dek = Crypto.generate_dek()
    for _ <- 1..50 do
      pt = :crypto.strong_rand_bytes(:rand.uniform(200))
      ct = Crypto.encrypt(dek, pt)
      assert {:ok, ^pt} = Crypto.decrypt(dek, ct)
    end
  end

  test "wrap/unwrap round-trips a DEK under the master" do
    master = Crypto.generate_dek()
    dek = Crypto.generate_dek()
    wrapped = Crypto.wrap(master, dek)
    assert wrapped != dek
    assert {:ok, ^dek} = Crypto.unwrap(master, wrapped)
  end

  test "red path: decrypt with the wrong DEK fails closed (never plaintext)" do
    dek = Crypto.generate_dek()
    wrong = Crypto.generate_dek()
    ct = Crypto.encrypt(dek, "secret")
    assert {:error, :decrypt_failed} = Crypto.decrypt(wrong, ct)
  end

  test "red path: tampered ciphertext fails the GCM tag check" do
    dek = Crypto.generate_dek()
    <<head::binary-size(30), byte, rest::binary>> = Crypto.encrypt(dek, "secret-value-1234567890")
    tampered = <<head::binary, bxor(byte, 0xFF), rest::binary>>
    assert {:error, :decrypt_failed} = Crypto.decrypt(dek, tampered)
  end

  test "ciphertext is not the plaintext and differs across encryptions (random IV)" do
    dek = Crypto.generate_dek()
    a = Crypto.encrypt(dek, "same")
    b = Crypto.encrypt(dek, "same")
    assert a != b
    refute a =~ "same"
  end

  test "pseudonym is deterministic per (DEK, subject) and DEK-bound" do
    dek1 = Crypto.generate_dek()
    dek2 = Crypto.generate_dek()
    assert Crypto.pseudonym(dek1, "s1") == Crypto.pseudonym(dek1, "s1")
    assert Crypto.pseudonym(dek1, "s1") != Crypto.pseudonym(dek1, "s2")
    # A different DEK yields a different pseudonym → destroying the DEK makes it
    # unreconstructable (RQ5).
    assert Crypto.pseudonym(dek1, "s1") != Crypto.pseudonym(dek2, "s1")
    # 32-byte HMAC → 64 hex chars.
    assert byte_size(Crypto.pseudonym(dek1, "s1")) == 64
  end
end
