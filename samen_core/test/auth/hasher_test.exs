defmodule Samen.Auth.HasherTest do
  @moduledoc """
  ADR-035 §4.4 — the default PBKDF2-SHA256 hasher. Never stores/returns the
  plaintext password; verify is a round trip under the persisted scheme; a wrong
  password (red path) fails, the correct one (positive control) passes.
  """
  use ExUnit.Case, async: true

  alias Samen.Auth.Hasher
  alias Samen.Auth.Hasher.Pbkdf2

  test "hash/1 never returns the plaintext password" do
    {hash, scheme} = Hasher.hash("correct horse battery staple")
    refute hash == "correct horse battery staple"
    assert scheme == "pbkdf2-sha256$600000"
  end

  test "two hashes of the SAME password are different (fresh salt per call)" do
    {hash1, _} = Hasher.hash("same-password-both-times")
    {hash2, _} = Hasher.hash("same-password-both-times")
    refute hash1 == hash2
  end

  test "verify/3 positive control: the correct password verifies" do
    {hash, scheme} = Hasher.hash("s3cure-enough-password")
    assert Hasher.verify("s3cure-enough-password", hash, scheme)
  end

  test "verify/3 RED PATH: the wrong password is refused" do
    {hash, scheme} = Hasher.hash("s3cure-enough-password")
    refute Hasher.verify("totally-different-password", hash, scheme)
  end

  test "verify/3 never raises on a malformed hash/scheme" do
    refute Hasher.verify("anything", "not-a-valid-hash", "pbkdf2-sha256$600000")
    refute Hasher.verify("anything", "salt.digest", "not-a-known-scheme")
  end

  test "Pbkdf2 is the configured default adapter" do
    assert Hasher.adapter() == Pbkdf2
  end
end
