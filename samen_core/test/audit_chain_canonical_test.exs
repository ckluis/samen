defmodule Samen.AuditChain.CanonicalTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): `Samen.AuditChain.Canonical` is what the audit hash chain COMMITS. A change to how a
  value encodes silently re-hashes every future entry and makes the tamper check disagree with the writer, so the
  encoding is pinned against golden strings and the SHA-256 preimage is checked independently.
  """
  use ExUnit.Case, async: true

  alias Samen.AuditChain.Canonical

  test "encode/1: sorted keys, no whitespace, explicit null, booleans, integers, escaped strings, ISO-8601 times" do
    at = ~U[2026-01-02 03:04:05.000006Z]

    assert Canonical.encode(%{
             z: nil,
             a: true,
             b: false,
             n: -7,
             s: "q\"\\\n\r\t",
             t: at
           }) ==
             ~s({"a":true,"b":false,"n":-7,"s":"q\\"\\\\\\n\\r\\t","t":"2026-01-02T03:04:05.000006Z","z":null})

    assert Canonical.encode(%{}) == "{}"
  end

  test "hash/2 is SHA-256(prior <> canonical json), lower hex — and moves with every input" do
    payload = %{a: true, b: false, n: 1}
    expected = :crypto.hash(:sha256, "prior" <> ~s({"a":true,"b":false,"n":1})) |> Base.encode16(case: :lower)

    assert Canonical.hash("prior", payload) == expected
    refute Canonical.hash("other", payload) == expected
    refute Canonical.hash("prior", %{payload | a: false}) == expected
    refute Canonical.hash("prior", %{payload | b: true}) == expected
  end

  test "hash/2 refuses a non-binary prior hash or a non-map payload by function clause" do
    # via apply/3: the compiler would otherwise (rightly) warn that these calls can never match the spec
    for args <- [[5, %{a: 1}], ["p", [a: 1]], [nil, nil]] do
      assert_raise FunctionClauseError, fn -> apply(Canonical, :hash, args) end
    end
  end
end
