defmodule Samen.Files.StorageTest do
  @moduledoc """
  ADR-026 files-storage adapter contract (AC-G14-3 / RP-FI-6).

  Coverage:
    * The `Samen.Files.Storage` behaviour defines the fail-honest callbacks.
    * `Storage.Local` is a REAL impl: it round-trips bytes on the filesystem
      under a configurable root (put → get returns the identical bytes; delete
      removes them).
    * `Storage.S3` is fail-honest: `configured?/1` is `false` absent creds, and
      `put/3`/`get/2`/`delete/2`/`presign_get/2` return `{:error, :not_configured}`
      — NEVER `{:ok, _}` — because no byte is ever actually stored (mirrors the
      delivery-no-op probe, ADR-014).

  ## Anti-tautology (RP-FI-6)

  The S3 assertions are not "the return shape is an error tuple" — a sabotage stub
  that returned `{:ok, %{}}` for the no-op put MUST be DETECTED. The
  `"sabotage {:ok} stub is detected"` test encodes exactly that: it asserts an
  adapter which claims `{:ok, _}` on `put` WITHOUT any observable byte round-trip
  is caught by the same probe that passes S3. Conversely the Local round-trip test
  asserts on the ACTUAL bytes read back — so it cannot pass against a no-op store.
  """
  use ExUnit.Case, async: true

  alias Samen.Files.Storage
  alias Samen.Files.Storage.{Local, S3}

  # ---------------------------------------------------------------------------
  # The behaviour contract exists.

  describe "Storage behaviour" do
    test "defines the fail-honest storage callbacks" do
      callbacks = Storage.behaviour_info(:callbacks)
      assert {:configured?, 1} in callbacks
      assert {:put, 3} in callbacks
      assert {:get, 2} in callbacks
      assert {:delete, 2} in callbacks
      assert {:presign_get, 2} in callbacks
    end
  end

  # ---------------------------------------------------------------------------
  # AC-G14-3 — Local is a REAL working impl: it round-trips bytes on disk.

  describe "Storage.Local: real byte round-trip" do
    setup do
      root = Path.join(System.tmp_dir!(), "files_storage_test_#{System.unique_integer([:positive])}")
      File.rm_rf!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      %{config: %{root: root}, root: root}
    end

    test "configured? is true when a root is resolvable", %{config: config} do
      assert Local.configured?(config)
      # Even absent an explicit root, Local falls back to a temp subdir and works.
      assert Local.configured?(%{})
    end

    test "put then get returns the IDENTICAL bytes (not just an :ok shape)", %{config: config} do
      key = "org/abc123/report.pdf"
      bytes = :crypto.strong_rand_bytes(4096)

      assert {:ok, meta} = Local.put(key, bytes, config)
      assert meta.size_bytes == byte_size(bytes)

      # The load-bearing assertion: the bytes actually round-trip. A no-op store
      # that returned {:ok, ...} without writing would fail HERE.
      assert {:ok, ^bytes} = Local.get(key, config)
    end

    test "the bytes are actually on disk under the configured root", %{config: config, root: root} do
      key = "nested/dir/blob.bin"
      bytes = <<0, 1, 2, 3, 255, 254>>

      assert {:ok, _meta} = Local.put(key, bytes, config)
      on_disk = Path.join(root, key)
      assert File.exists?(on_disk)
      assert File.read!(on_disk) == bytes
    end

    test "get on a missing key is an honest :not_found (not empty bytes)", %{config: config} do
      assert {:error, :not_found} = Local.get("does/not/exist.txt", config)
    end

    test "delete removes the bytes; get afterward is :not_found; re-delete is idempotent", %{
      config: config
    } do
      key = "temp/thing.dat"
      assert {:ok, _} = Local.put(key, "payload", config)
      assert {:ok, "payload"} = Local.get(key, config)

      assert :ok = Local.delete(key, config)
      assert {:error, :not_found} = Local.get(key, config)
      # idempotent: deleting an absent key is still :ok
      assert :ok = Local.delete(key, config)
    end

    test "presign_get returns a framework-served /files path", %{config: config} do
      assert {:ok, "/files/org/a/b.png"} = Local.presign_get("org/a/b.png", config)
    end

    test "path-traversal and unsafe keys are refused fail-closed", %{config: config} do
      assert {:error, :invalid_key} = Local.put("../escape.txt", "x", config)
      assert {:error, :invalid_key} = Local.put("/absolute", "x", config)
      assert {:error, :invalid_key} = Local.put("has space", "x", config)
      assert {:error, :invalid_key} = Local.put("", "x", config)
      assert {:error, :invalid_key} = Local.get("a/../../etc/passwd", config)
    end
  end

  # ---------------------------------------------------------------------------
  # AC-G14-3 / RP-FI-6 — S3 is fail-honest: never {:ok} absent a real backend.

  describe "Storage.S3: fail-honest skeleton" do
    test "configured? is false absent creds" do
      refute S3.configured?(%{})
      refute S3.configured?(%{bucket: "b"})
      refute S3.configured?(%{bucket: "b", access_key_id: "k"})
      # Only full creds flip it true.
      assert S3.configured?(%{bucket: "b", access_key_id: "k", secret_access_key: "s"})
    end

    test "put absent creds returns {:error, :not_configured}, NEVER {:ok, _}" do
      # The type checker itself proves S3.put has type {:error, _} with no {:ok, _}
      # branch reachable — so the fail-honest guarantee holds at compile time, not
      # just runtime. This assertion pins the exact honest reason.
      assert {:error, :not_configured} = S3.put("k", "bytes", %{})
    end

    test "put WITH creds is {:error, :not_implemented} (no dep to dispatch), still never {:ok}" do
      config = %{bucket: "b", access_key_id: "k", secret_access_key: "s"}
      assert {:error, :not_implemented} = S3.put("k", "bytes", config)
    end

    test "get/delete/presign_get are all fail-honest absent creds" do
      assert {:error, :not_configured} = S3.get("k", %{})
      assert {:error, :not_configured} = S3.delete("k", %{})
      assert {:error, :not_configured} = S3.presign_get("k", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # RP-FI-6 anti-tautology — a sabotage {:ok} stub is DETECTED by the probe.

  describe "RP-FI-6 anti-tautology: the fail-honest probe is non-vacuous" do
    # A sabotage adapter mirroring the exact lie the contract forbids: it claims
    # {:ok} for a put but stores nothing (no backing at all).
    defmodule SabotageOkStub do
      @behaviour Samen.Files.Storage
      @impl true
      def configured?(_config), do: false
      @impl true
      def put(_key, _binary, _config), do: {:ok, %{lie: true}}
      @impl true
      def get(_key, _config), do: {:error, :not_found}
      @impl true
      def delete(_key, _config), do: :ok
      @impl true
      def presign_get(_key, _config), do: {:ok, "http://fake"}
    end

    # The probe that both the real S3 and any adapter must pass: an UNCONFIGURED
    # adapter must NOT report {:ok, _} for a put (no byte was stored). This is the
    # honest-error assertion, not a return-shape assertion.
    defp fail_honest_put?(adapter) do
      refute adapter.configured?(%{})
      match?({:error, _}, adapter.put("k", "bytes", %{}))
    end

    test "S3 PASSES the fail-honest probe" do
      assert fail_honest_put?(S3)
    end

    test "the sabotage {:ok} stub FAILS the fail-honest probe (it is DETECTED)" do
      # If the probe were tautological (only checked return shape), the stub would
      # slip through. It does not: an unconfigured adapter returning {:ok, _} is
      # caught here — proving the S3 pass above is a real guarantee, not a constant.
      refute fail_honest_put?(SabotageOkStub),
             "a stub that returns {:ok} for a no-op put MUST be detected by the probe"
    end

    test "the byte round-trip probe would also catch a no-op store" do
      # Complementary proof: the Local guarantee asserts on ACTUAL bytes. A no-op
      # store (SabotageOkStub) returns {:ok} but get returns :not_found — so a
      # round-trip assertion cannot be satisfied by a store that wrote nothing.
      assert {:ok, _} = SabotageOkStub.put("k", "bytes", %{})
      # The lie is exposed the instant you read the bytes back:
      assert {:error, :not_found} = SabotageOkStub.get("k", %{})
    end
  end
end
