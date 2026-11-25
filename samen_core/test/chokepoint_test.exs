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
    vault_src = Samen.SourceScan.read!(Path.join(@lib_dir, "samen/vault.ex"))
    assert vault_src =~ "defp do_decrypt(dek, ciphertext)"
    # The decrypt call lives inside do_decrypt only.
    assert vault_src =~ "Crypto.decrypt(dek, ciphertext)"
  end

  # ===================================================================
  # RED PATH / anti-tautology: a planted SECOND decrypt call site is caught
  # ===================================================================

  # `File.cp_r!` is ~750 calls (list, stat, copy per entry) into the node's single `:file_server_2`, queued behind every
  # other test's file I/O: 267 ms alone, 3,096 ms behind 40 processes doing file I/O, and it outran ExUnit's 60 s in this
  # setup on a loaded machine. This copies the tree through `:prim_file` (what `:raw` mode uses), which never queues.
  defp copy_tree!(src, dst) do
    case :prim_file.make_dir(dst) do
      r when r in [:ok, {:error, :eexist}] -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "make directory", path: dst
    end

    {:ok, names} = :prim_file.list_dir(src)

    for name <- Enum.map(names, &to_string/1) do
      from = Path.join(src, name)
      to = Path.join(dst, name)

      # read_link_info does not follow links: a symlink (valid, looping or dangling) is refused loudly rather than
      # recursed into or crashing as a CaseClauseError. lib/ has none today.
      case :prim_file.read_link_info(from) do
        {:ok, info} when elem(info, 2) == :directory ->
          copy_tree!(from, to)

        {:ok, info} when elem(info, 2) == :regular ->
          case :prim_file.write_file(to, Samen.SourceScan.read!(from)) do
            :ok -> :ok
            {:error, reason} -> raise File.Error, reason: reason, action: "write to file", path: to
          end

        {:ok, info} ->
          raise "copy_tree!: #{from} is a #{elem(info, 2)} (a symlink or special file); only directories and regular files are copied, and #{@lib_dir} has no symlinks"

        {:error, reason} ->
          raise File.Error, reason: reason, action: "stat", path: from
      end
    end

    :ok
  end

  describe "copy_tree!" do
    setup do
      src = Path.join(System.tmp_dir!(), "samen_copy_tree_#{System.unique_integer([:positive])}")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "real.ex"), "x")
      on_exit(fn -> File.rm_rf!(src) end)
      %{src: src}
    end

    test "copies regular files and nested directories", %{src: src} do
      File.mkdir_p!(Path.join(src, "sub/deeper"))
      File.write!(Path.join(src, "sub/deeper/b.ex"), "y")
      dst = src <> "_dst"
      on_exit(fn -> File.rm_rf!(dst) end)
      assert copy_tree!(src, dst) == :ok
      assert Samen.SourceScan.read!(Path.join(dst, "sub/deeper/b.ex")) == "y"
    end

    test "a symlink to a file fails loudly with a clear message", %{src: src} do
      :ok = File.ln_s(Path.join(src, "real.ex"), Path.join(src, "link.ex"))
      dst = src <> "_dst"
      on_exit(fn -> File.rm_rf!(dst) end)
      e = assert_raise RuntimeError, fn -> copy_tree!(src, dst) end
      assert e.message =~ "symlink"
      assert e.message =~ "link.ex"
    end

    test "a dangling symlink fails loudly (not a CaseClauseError)", %{src: src} do
      :ok = File.ln_s(Path.join(src, "nowhere.ex"), Path.join(src, "dangling.ex"))
      dst = src <> "_dst"
      on_exit(fn -> File.rm_rf!(dst) end)
      e = assert_raise RuntimeError, fn -> copy_tree!(src, dst) end
      assert e.message =~ "dangling.ex"
    end
  end

  describe "RED PATH — a second decrypt call site is caught" do
    setup do
      scratch =
        Path.join(System.tmp_dir!(), "samen_chokepoint_#{System.unique_integer([:positive])}")

      File.rm_rf!(scratch)
      File.mkdir_p!(Path.join(scratch, "samen"))

      # Copy the real lib tree into the scratch dir.
      copy_tree!(@lib_dir, scratch)

      on_exit(fn -> File.rm_rf!(scratch) end)
      {:ok, scratch: scratch}
    end

    test "the scratch copy is the real tree: same files, same bytes", %{scratch: scratch} do
      real = Samen.SourceScan.files(@lib_dir, [".ex"])
      copy = Samen.SourceScan.files(scratch, [".ex"])

      assert length(real) > 500
      assert Enum.map(copy, &Path.relative_to(&1, scratch)) == Enum.map(real, &Path.relative_to(&1, @lib_dir))
      assert Enum.map(copy, &Samen.SourceScan.read!/1) == Enum.map(real, &Samen.SourceScan.read!/1)
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
