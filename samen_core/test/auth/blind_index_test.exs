defmodule Samen.Auth.BlindIndexTest do
  @moduledoc """
  ADR-035 §4.1 — the blind-index email lookup. Non-reversible (keyed HMAC),
  deterministic under normalization, and — the red test — never equal to the
  plaintext or the lowercased email (INV-1: no plaintext identity column, not
  even a lookup index that IS the plaintext under a different name).
  """
  use ExUnit.Case, async: false

  alias Samen.Auth.BlindIndex
  alias Samen.Kms

  setup do
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked) end)
    :ok
  end

  test "computes a deterministic hex digest, distinct from the plaintext/lowercased email" do
    email = "  Alice@Example.TEST  "
    assert {:ok, bidx} = BlindIndex.compute(email)

    # RED PATH: the index is never the plaintext, never the trimmed/lowercased
    # form — a keyed HMAC digest, not a disguised plaintext column (INV-1).
    refute bidx == email
    refute bidx == BlindIndex.normalize(email)
    refute String.contains?(String.downcase(bidx), "alice")
    refute String.contains?(String.downcase(bidx), "example.test")

    # Deterministic: recomputing the SAME normalized email yields the SAME index.
    assert {:ok, ^bidx} = BlindIndex.compute("alice@example.test")
  end

  test "normalization: trim + NFC + lowercase collapse to one index" do
    assert {:ok, canonical} = BlindIndex.compute("bob@example.test")
    assert {:ok, spaced} = BlindIndex.compute("  bob@example.test  ")
    assert {:ok, upper} = BlindIndex.compute("BOB@EXAMPLE.TEST")

    assert canonical == spaced
    assert canonical == upper
  end

  test "a different email computes a different index" do
    assert {:ok, a} = BlindIndex.compute("first@example.test")
    assert {:ok, b} = BlindIndex.compute("second@example.test")
    refute a == b
  end

  test "k_bidx is provisioned under the reserved synthetic subject sys:bidx" do
    assert BlindIndex.bidx_subject() == "sys:bidx"
    assert {:ok, _bidx} = BlindIndex.compute("provision-check@example.test")
    assert {:ok, %{state: :active}} = Kms.adapter().attest(BlindIndex.bidx_subject())
  end
end
