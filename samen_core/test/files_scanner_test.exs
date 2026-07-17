defmodule Samen.FilesScannerTest do
  @moduledoc """
  WS-E E1.3 — the `Samen.Files.Scanner` behaviour + `Reject` default + `Noop` explicit
  opt-in, and the scan-gated quarantine → active promotion (ADR-026 §2, decision 3 ·
  AC-G14-4 · RP-FI-3). Exercised against a REAL Postgres DB via the `nef`-abbrev
  `SamenCore.Support.NotificationFixture.File` resource and the REAL
  `Samen.Files.Storage.Local` adapter.

  Guarantees proven (each with a green path AND a red/anti-tautology twin):

    * **Scanner behaviour + honest defaults** — `Reject` (the DEFAULT) holds every
      file (`{:ok, :held}`); `Noop` (explicit opt-in) clears every file
      (`{:ok, :clean}`). `Reject` NEVER returns `{:ok, :clean}` — the fail-honest rule.
    * **AC-G14-4 quarantine fail-closed** — a fresh upload is `:quarantined`;
      `previewable?/1` is false and `fetch_bytes/3` refuses to serve its bytes.
    * **Promotion gated on a clean scan** — with `Noop` configured, `promote/3`
      promotes to `:active` and `fetch_bytes/3` then serves the bytes. With the default
      `Reject`, `promote/3` returns `{:ok, :held, file}` and the file STAYS
      `:quarantined` (not previewable) — the fail-closed default.
    * **RP-FI-3 anti-tautology** — a `SabotageAlwaysClean` scanner that lies
      `{:ok, :clean}` for held content IS what promotes the file; the must-fail probe
      proves the gate is the scan verdict, not the call itself. And a direct promotion
      that skips the scan (sabotaging the gate) is DETECTED: promoting a file whose
      scanner would hold it must NOT reach `:active`.

  ## Anti-tautology

  The promotion tests do not merely assert a return shape — they assert the CONCRETE
  `:active`/`:quarantined` status read back from the DB. A file promoted by a lying
  scanner reaches `:active` (proving the gate is non-vacuous — a different verdict
  yields a different DB state); a file scanned by `Reject` stays `:quarantined` (proving
  the default is fail-closed). `fetch_bytes/3` on a quarantined file returns
  `:not_previewable` BEFORE storage is read — an over-permissive gate would leak bytes
  and be caught.
  """
  use ExUnit.Case, async: false

  alias Samen.Files
  alias Samen.Files.Scanner
  alias Samen.Files.Storage.Local
  alias SamenCore.TestRepo
  alias SamenCore.Support.NotificationFixture.File, as: FileResource

  # A scanner that LIES: it returns {:ok, :clean} for content the default holds. Used
  # ONLY to prove the promotion gate is driven by the scan verdict (anti-tautology): if
  # this promotes and Reject does not, the gate is non-vacuous.
  defmodule SabotageAlwaysClean do
    @behaviour Samen.Files.Scanner
    @impl true
    def scan(_binary, _config), do: {:ok, :clean}
  end

  # A scanner whose scan cannot run — proves a scan error is fail-closed (never promotes).
  defmodule SabotageErroring do
    @behaviour Samen.Files.Scanner
    @impl true
    def scan(_binary, _config), do: {:error, :backend_down}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    root =
      Path.join(
        System.tmp_dir!(),
        "files_scanner_test_#{System.unique_integer([:positive])}"
      )

    Elixir.File.rm_rf!(root)
    on_exit(fn -> Elixir.File.rm_rf!(root) end)

    %{root: root, storage_config: %{root: root}}
  end

  defp base_opts(ctx, overrides \\ []) do
    Keyword.merge(
      [
        file_module: FileResource,
        repo: TestRepo,
        storage: Local,
        storage_config: ctx.storage_config,
        max_bytes: 1_000_000,
        allowed_content_types: ~w(image/png text/plain application/pdf)
      ],
      overrides
    )
  end

  defp scope(overrides \\ %{}) do
    Map.merge(%{org_id: Ash.UUID.generate(), actor_id: Ash.UUID.generate()}, overrides)
  end

  # Fail-honest probe: dispatch through a VARIABLE module so the type-checker cannot
  # statically narrow the return. Returns true iff the scanner does NOT claim `:clean`
  # for held content — i.e. it is honest about not having cleared it. `Reject` PASSES;
  # a lying always-clean scanner FAILS. This is the anti-tautology hinge: the same
  # probe that Reject passes is the one the sabotage stub fails.
  defp holds_not_clean?(scanner_mod) do
    case apply(scanner_mod, :scan, ["held content bytes", %{}]) do
      {:ok, :clean} -> false
      _ -> true
    end
  end

  defp upload_quarantined(ctx) do
    sc = scope()
    pl = %{filename: "held.txt", content_type: "text/plain", binary: "scan me please"}
    {:ok, file} = Files.upload(sc, pl, base_opts(ctx))
    {sc, file}
  end

  # ---------------------------------------------------------------------------
  # Scanner behaviour + honest defaults

  describe "Scanner behaviour + Reject/Noop honest defaults" do
    test "Scanner defines the fail-honest scan callback" do
      cbs = Scanner.behaviour_info(:callbacks)
      assert {:scan, 2} in cbs
    end

    test "Reject (the DEFAULT) holds every file — {:ok, :held}, NEVER {:ok, :clean}" do
      assert {:ok, :held} = Scanner.Reject.scan("any bytes at all", %{})

      # The load-bearing fail-honest rule: the non-scanning default must NEVER claim
      # clean. Dispatch through a variable module so the check is a real runtime probe
      # (not statically narrowed away by the type-checker) — the SAME probe a lying
      # scanner would FAIL. `holds_not_clean?/1` returns true iff the scanner declines
      # to claim clean for held content.
      assert holds_not_clean?(Scanner.Reject)
      # And the probe is non-vacuous: an always-clean scanner is DETECTED (fails it).
      refute holds_not_clean?(SabotageAlwaysClean)
    end

    test "Noop (explicit opt-in) clears every file — {:ok, :clean}" do
      assert {:ok, :clean} = Scanner.Noop.scan("any bytes at all", %{})
    end
  end

  # ---------------------------------------------------------------------------
  # AC-G14-4 · fresh upload is quarantined; preview/download refused

  describe "fresh upload is :quarantined; preview/download refused (AC-G14-4)" do
    test "a freshly uploaded file is :quarantined and NOT previewable", ctx do
      {_sc, file} = upload_quarantined(ctx)

      assert file.status == :quarantined
      refute Files.previewable?(file)
    end

    test "fetch_bytes/3 refuses a :quarantined file BEFORE touching storage", ctx do
      {sc, file} = upload_quarantined(ctx)

      # Even though the bytes ARE on disk (upload stored them), the gate refuses to serve
      # them while quarantined — and refuses BEFORE storage is read.
      assert {:error, :not_previewable} = Files.fetch_bytes(sc, file, base_opts(ctx))

      # Anti-tautology: the bytes genuinely exist on disk, so the refusal is the STATUS
      # gate, not a missing object. Reading storage directly still returns them.
      assert {:ok, "scan me please"} = Local.get(file.storage_key, ctx.storage_config)
    end
  end

  # ---------------------------------------------------------------------------
  # Promotion gated on a clean scan

  describe "quarantine → active promotion gated on a scan pass" do
    test "with Noop configured, promote/3 clears the file to :active and preview works", ctx do
      {sc, file} = upload_quarantined(ctx)

      assert {:ok, promoted} =
               Files.promote(sc, file, base_opts(ctx, scanner: Scanner.Noop))

      assert promoted.status == :active
      assert Files.previewable?(promoted)

      # Persisted, not just an in-memory struct.
      reloaded = Ash.get!(FileResource, promoted.id, authorize?: false)
      assert reloaded.status == :active

      # And now the bytes are servable through the gated path.
      assert {:ok, "scan me please"} = Files.fetch_bytes(sc, reloaded, base_opts(ctx))
    end

    test "with the DEFAULT Reject scanner, promote/3 holds the file — it STAYS :quarantined",
         ctx do
      {sc, file} = upload_quarantined(ctx)

      # No :scanner opt → the @default_scanner (Reject) governs. Fail-closed.
      assert {:ok, :held, held} = Files.promote(sc, file, base_opts(ctx))
      assert held.status == :quarantined

      # DB re-read proves nothing was promoted.
      reloaded = Ash.get!(FileResource, file.id, authorize?: false)
      assert reloaded.status == :quarantined
      refute reloaded.status == :active

      # And the bytes remain unservable.
      assert {:error, :not_previewable} = Files.fetch_bytes(sc, reloaded, base_opts(ctx))
    end

    test "a scan that cannot run is fail-closed — {:error, {:scan_failed, _}}, file held", ctx do
      {sc, file} = upload_quarantined(ctx)

      assert {:error, {:scan_failed, :backend_down}} =
               Files.promote(sc, file, base_opts(ctx, scanner: SabotageErroring))

      reloaded = Ash.get!(FileResource, file.id, authorize?: false)
      assert reloaded.status == :quarantined
    end

    test "promote/3 on an already-:active file is a no-op {:error, :already_active}", ctx do
      {sc, file} = upload_quarantined(ctx)
      {:ok, promoted} = Files.promote(sc, file, base_opts(ctx, scanner: Scanner.Noop))

      assert {:error, :already_active} =
               Files.promote(sc, promoted, base_opts(ctx, scanner: Scanner.Noop))
    end

    test "a promotion writes a token-only primitives.file.promoted audit row", ctx do
      {sc, file} = upload_quarantined(ctx)
      {:ok, promoted} = Files.promote(sc, file, base_opts(ctx, scanner: Scanner.Noop))

      %{rows: [[detail]]} =
        TestRepo.query!(
          "SELECT aud_detail FROM aud_event WHERE aud_subject_id = $1 AND aud_detail LIKE $2",
          [to_string(promoted.id), "%file.promoted%"]
        )

      assert detail =~ "primitives.file.promoted"
      assert detail =~ "verdict=clean"
      # Token-only: never the filename or storage_key.
      refute detail =~ "held.txt"
      refute detail =~ promoted.storage_key
    end
  end

  # ---------------------------------------------------------------------------
  # RP-FI-3 · anti-tautology — the gate IS the scan verdict

  describe "RP-FI-3 anti-tautology: the promotion gate is the scan verdict" do
    test "a lying SabotageAlwaysClean scanner IS what promotes — proving the gate is non-vacuous",
         ctx do
      {sc, file} = upload_quarantined(ctx)

      # The SAME held content, scanned by a scanner that LIES {:ok, :clean}, promotes.
      # This proves the promotion is DRIVEN by the verdict: swap the verdict, get a
      # different DB state. Paired with the Reject test above (same content → stays
      # quarantined), the gate is proven non-tautological.
      assert {:ok, promoted} =
               Files.promote(sc, file, base_opts(ctx, scanner: SabotageAlwaysClean))

      assert promoted.status == :active

      reloaded = Ash.get!(FileResource, promoted.id, authorize?: false)
      assert reloaded.status == :active
    end

    test "the must-fail probe: promoting under Reject must NOT reach :active (gate holds)", ctx do
      {sc, file} = upload_quarantined(ctx)

      # This is the RP-FI-3 red path expressed as a live assertion: the default scanner
      # holds the file, so it must NOT be :active. If the promotion gate were sabotaged
      # to promote-without-a-clean-scan, this assertion FAILS (the file would be :active).
      assert {:ok, :held, _held} = Files.promote(sc, file, base_opts(ctx))
      reloaded = Ash.get!(FileResource, file.id, authorize?: false)
      refute reloaded.status == :active
      assert reloaded.status == :quarantined
    end
  end
end
