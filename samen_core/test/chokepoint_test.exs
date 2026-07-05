defmodule Samen.ChokepointTest do
  @moduledoc """
  T1.5 clause (b): exactly ONE decrypt chokepoint, proven by the structural
  single-chokepoint scanner (ported from the S0.5 spike `plaintext_leak_test`).

  Red path: a SECOND `Crypto.decrypt(` call site anywhere in `lib/` is caught.
  We prove the scanner is non-vacuous (anti-tautology) by running it against a
  scratch copy of the source tree with a planted second decrypt call and asserting
  it flips to an error.

  The scanner's literal-match limitation (aliased / fully-qualified / `:crypto`
  primitive calls evade it) is documented on `Samen.Chokepoint`; C3 `pii_reads`
  (T1.8b) is the real check. This test asserts the single-chokepoint property for
  the real tree AND that the cheap in-repo backstop actually fires.
  """
  use ExUnit.Case, async: true

  alias Samen.Chokepoint

  @lib_dir Path.expand("../lib", __DIR__)

  test "there is exactly ONE Crypto.decrypt/2 call site, in Samen.Vault" do
    assert Chokepoint.single_chokepoint(@lib_dir) == :ok
  end

  test "the single sanctioned call site is samen/vault.ex" do
    assert [{"samen/vault.ex", _line, _n}] = Chokepoint.decrypt_call_sites(@lib_dir)
  end

  test "the sanctioned chokepoint function is do_decrypt in vault.ex" do
    vault_src = File.read!(Path.join(@lib_dir, "samen/vault.ex"))
    assert vault_src =~ "defp do_decrypt(dek, ciphertext)"
    # The decrypt call lives inside do_decrypt only.
    assert vault_src =~ "Crypto.decrypt(dek, ciphertext)"
  end

  # ===================================================================
  # RED PATH / anti-tautology: a planted SECOND decrypt call site is caught
  # ===================================================================

  describe "RED PATH — a second decrypt call site is caught" do
    setup do
      scratch =
        Path.join(System.tmp_dir!(), "samen_chokepoint_#{System.unique_integer([:positive])}")

      File.rm_rf!(scratch)
      File.mkdir_p!(Path.join(scratch, "samen"))

      # Copy the real lib tree into the scratch dir.
      File.cp_r!(@lib_dir, scratch)

      on_exit(fn -> File.rm_rf!(scratch) end)
      {:ok, scratch: scratch}
    end

    test "scanner flips to error when a second Crypto.decrypt( is planted", %{scratch: scratch} do
      # Baseline: the copied tree still passes (one chokepoint).
      assert Chokepoint.single_chokepoint(scratch) == :ok

      # Plant a laundering second decrypt in a NON-sanctioned module.
      rogue = Path.join(scratch, "samen/rogue_leak.ex")

      File.write!(rogue, """
      defmodule Samen.RogueLeak do
        alias Samen.Kms.Crypto
        def leak(dek, blob) do
          {:ok, plaintext} = Crypto.decrypt(dek, blob)
          plaintext
        end
      end
      """)

      # The scanner must now report TWO call sites → error, naming the rogue file.
      assert {:error, msg} = Chokepoint.single_chokepoint(scratch)
      assert msg =~ "rogue_leak.ex"
      assert length(Chokepoint.decrypt_call_sites(scratch)) == 2
    end

    test "documented limitation: an aliased/renamed decrypt evades the literal scan", %{
      scratch: scratch
    } do
      # This proves the KNOWN limitation honestly: the literal scanner does NOT
      # catch `C.decrypt(` when the module is aliased to a different name. C3
      # pii_reads (T1.8b) is the real check for this. If this ever starts being
      # caught (scanner upgraded), update Samen.Chokepoint's moduledoc.
      rogue = Path.join(scratch, "samen/aliased_leak.ex")

      File.write!(rogue, """
      defmodule Samen.AliasedLeak do
        alias Samen.Kms.Crypto, as: C
        def leak(dek, blob), do: C.decrypt(dek, blob)
      end
      """)

      # Still :ok — the literal `Crypto.decrypt(` scan misses `C.decrypt(`.
      assert Chokepoint.single_chokepoint(scratch) == :ok
    end
  end
end
