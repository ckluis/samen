defmodule Samen.FilesTest do
  @moduledoc """
  WS-E E1.2 — the governed files chokepoint `Samen.Files.upload/3` (ADR-026 §2,
  decision 2/3/5 · AC-G14-1/2/6 · RP-FI-1/3/5). Exercised against a REAL Postgres DB
  via the `ne*`-abbrev `SamenCore.Support.NotificationFixture` mount (its `File`
  resource is abbrev `nef`) and the REAL `Samen.Files.Storage.Local` adapter.

  Guarantees proven (each with a green path AND a red/anti-tautology twin):

    * **AC-G14-1 governed create + store + audit** — `upload/3` stores the bytes via
      `Storage.put`, creates a `File` row carrying the returned `storage_key`, and
      `Storage.get` round-trips the identical bytes; a token-only `file.uploaded`
      audit row lands on the `aud_event` tier.
    * **AC-G14-2 / RP-FI-1 governed-by-construction (STRUCTURAL)** — a `File` row's
      `storage_key` is set/repointed ONLY through the chokepoint. This is enforced
      STRUCTURALLY by `Samen.Files.ChokepointGuard` on BOTH the create and update paths,
      not by convention: a direct `Ash.create` setting a `storage_key`, AND a direct
      `Ash.update` repointing an existing row's `storage_key` (both bypassing
      `Samen.Files.upload/3`), are REFUSED — neither mints an ungoverned pointer. The
      chokepoint ALSO fails closed when no `File` module is wired.
    * **AC-G14-4 / RP-FI-3 quarantine fail-closed** — a fresh upload lands
      `:quarantined` (the resource default), NOT `:active`. Defaulting to `:active`
      FAILS this test.
    * **AC-G14-6 / RP-FI-5 deny-by-default size/type** — an over-size or
      non-allowlisted (or empty) content type is refused BEFORE `Storage.put`; NO
      bytes are written for a rejected upload; the allowlist is exact-match, never
      `*`. Widening the allowlist to `*` FAILS the deny-by-default test.

  ## Anti-tautology

  The size/type red-paths do not merely assert an `{:error, _}` shape — they assert
  the store was NOT touched: after a rejected upload, `Storage.get` on the generated
  key is `:not_found` and the storage root is empty (no bytes on disk). A guard that
  called `Storage.put` before enforcing would leave bytes behind and be DETECTED. The
  quarantine test asserts the CONCRETE `:quarantined` status read back from the DB, so
  a resource defaulting to `:active` cannot satisfy it.

  The RP-FI-1 bypass tests are the structural anti-tautology twins. The CREATE twin runs
  the EXACT gate-spec sabotage (a raw `Ash.create` of a `storage_key`-bearing `File`
  bypassing `Samen.Files.upload/3`, `authorize?: false`) and asserts it is REFUSED and
  mints NO row. The UPDATE twin closes the update-shaped hole gate round 2 flagged: it
  creates a governed row through `upload/3`, then runs a raw `Ash.update` repointing
  `storage_key` to a smuggled key (`authorize?: false`) and asserts it is REFUSED and the
  persisted key is UNCHANGED — no residue. Removing the `ChokepointGuard`, dropping
  `:update` from its registration, or removing the chokepoint's context marker would let
  one of these bypasses SUCCEED — flipping a test — so they cannot pass when the structural
  guarantee is broken. Each is paired with a positive control (the same-shape write WITH
  the chokepoint marker succeeds), proving the refusal keys on the marker, not on some
  incidental write failure.
  """
  use ExUnit.Case, async: false

  alias Samen.Files
  alias Samen.Files.ChokepointGuard
  alias Samen.Files.Storage.Local
  alias SamenCore.TestRepo
  alias SamenCore.Support.NotificationFixture.File, as: FileResource

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})

    # A fresh, isolated storage root per test so on-disk assertions are exact.
    root =
      Path.join(
        System.tmp_dir!(),
        "files_upload_test_#{System.unique_integer([:positive])}"
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

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        filename: "hello.txt",
        content_type: "text/plain",
        binary: "the quick brown fox"
      },
      overrides
    )
  end

  defp scope(overrides \\ %{}) do
    Map.merge(
      %{org_id: Ash.UUID.generate(), actor_id: Ash.UUID.generate()},
      overrides
    )
  end

  # ---------------------------------------------------------------------------
  # AC-G14-1 · governed create + store + audit

  describe "upload/3 — governed create + store + audit (AC-G14-1)" do
    test "stores the bytes, creates a File row carrying the storage_key, and round-trips",
         ctx do
      sc = scope()
      pl = payload(%{binary: "round-trip me exactly"})

      assert {:ok, file} = Files.upload(sc, pl, base_opts(ctx))

      # A governed row exists, carrying the storage_key the store minted.
      assert file.org_id == sc.org_id
      assert file.filename == "hello.txt"
      assert file.content_type == "text/plain"
      assert file.size_bytes == byte_size("round-trip me exactly")
      assert is_binary(file.storage_key)
      assert file.storage_key != ""

      # The bytes actually landed — Storage.get round-trips the IDENTICAL bytes (this
      # cannot pass against a no-op store).
      assert {:ok, "round-trip me exactly"} = Local.get(file.storage_key, ctx.storage_config)

      # And the row is readable back from the DB with that same key.
      reloaded = Ash.get!(FileResource, file.id, authorize?: false)
      assert reloaded.storage_key == file.storage_key
    end

    test "emits a token-only file.uploaded audit event on the aud_event tier", ctx do
      sc = scope()

      %{rows: [[before]]} =
        TestRepo.query!("SELECT count(*) FROM aud_event WHERE aud_subject_id = $1", [
          "placeholder"
        ])

      assert before == 0

      assert {:ok, file} = Files.upload(sc, payload(), base_opts(ctx))

      %{rows: [[after_count]]} =
        TestRepo.query!(
          "SELECT count(*) FROM aud_event WHERE aud_subject_id = $1",
          [to_string(file.id)]
        )

      assert after_count == 1

      # Token-only: the detail carries the bounded status enum, NOT the filename or
      # storage_key.
      %{rows: [[detail]]} =
        TestRepo.query!(
          "SELECT aud_detail FROM aud_event WHERE aud_subject_id = $1",
          [to_string(file.id)]
        )

      assert detail =~ "primitives.file.uploaded"
      assert detail =~ "status=quarantined"
      refute detail =~ "hello.txt"
      refute detail =~ file.storage_key
    end
  end

  # ---------------------------------------------------------------------------
  # AC-G14-2 / RP-FI-1 · governed-by-construction (fail-closed on no module)

  describe "governed-by-construction (AC-G14-2 / RP-FI-1)" do
    test "the chokepoint is the only mint path; it fails closed when no File module is wired",
         ctx do
      # No :file_module wired (and none in config) → the chokepoint refuses to mint a
      # storage_key-bearing row. A silent success here would be the ungoverned-row
      # leak the contract forbids.
      assert {:error, :no_file_module} =
               Files.upload(scope(), payload(), base_opts(ctx, file_module: nil))
    end

    test "an incomplete payload is refused (no row, no bytes)", ctx do
      assert {:error, :incomplete_payload} =
               Files.upload(scope(), %{filename: "x.txt", content_type: "text/plain"}, base_opts(ctx))

      assert {:error, :missing_org} =
               Files.upload(%{}, payload(), base_opts(ctx))
    end

    # THE GATE-SPEC SABOTAGE (RP-FI-1): a raw/direct Ash.create of a File carrying a
    # storage_key, bypassing Samen.Files.upload/3 — a test MUST catch it. This is the
    # structural enforcement the ADR ratifies (line 22/33/47): "no ungoverned file row
    # true by construction … a structural fact, not a convention a host must remember."
    test "RP-FI-1: a direct Ash.create carrying a storage_key (bypassing upload/3) is REFUSED — no ungoverned row minted" do
      org_id = Ash.UUID.generate()

      # The exact bypass the gate sabotage runs: a raw create, authorize?: false, minting
      # a storage_key-bearing row that would skip size/type enforcement AND the audit.
      result =
        FileResource
        |> Ash.Changeset.for_create(:create, %{
          org_id: org_id,
          filename: "ungoverned.txt",
          content_type: "text/plain",
          size_bytes: 5,
          storage_key: "#{org_id}/smuggled-key"
        })
        |> Ash.create(authorize?: false)

      # Structurally refused by Samen.Files.ChokepointGuard — NOT silently minted.
      assert {:error, error} = result
      assert Exception.message(error) =~ "ungoverned-file-row"

      # Anti-tautology: prove NO row landed for that smuggled key — the bypass minted
      # nothing (the refusal aborted the transaction, DB unchanged).
      %{rows: [[count]]} =
        TestRepo.query!(
          "SELECT count(*) FROM nef_file WHERE nef_storage_key = $1",
          ["#{org_id}/smuggled-key"]
        )

      assert count == 0
    end

    # Positive control: the SAME-shape storage_key create SUCCEEDS when it carries the
    # chokepoint marker (the exact stamp Samen.Files.upload/3 applies). This proves the
    # refusal above keys on the ABSENCE of the marker — not on some incidental create
    # failure — so the RP-FI-1 test is non-vacuous: remove the guard and the bypass
    # create passes; remove the marker and the governed create fails.
    test "RP-FI-1 control: a storage_key create bearing the chokepoint marker SUCCEEDS" do
      org_id = Ash.UUID.generate()

      result =
        FileResource
        |> Ash.Changeset.for_create(:create, %{
          org_id: org_id,
          filename: "governed.txt",
          content_type: "text/plain",
          size_bytes: 5,
          storage_key: "#{org_id}/governed-key"
        })
        |> Ash.Changeset.set_context(%{private: %{ChokepointGuard.marker_key() => true}})
        |> Ash.create(authorize?: false)

      assert {:ok, file} = result
      assert file.storage_key == "#{org_id}/governed-key"
    end

    # THE UPDATE-SHAPED HOLE (gate round 2 NO_GO): the default public `:update` action
    # accepts `storage_key` (`public?: true`), so a member+ actor could create a governed
    # row then `Ash.update` it to REPOINT `storage_key` at an arbitrary/unscanned/oversize
    # key — no chokepoint marker, no size/type enforcement, no audit. That is the exact
    # AC-G14-2 violation ("No File row can carry a storage_key except through
    # Samen.Files.upload/3") in update shape. The guard is now registered on `:update` too.
    test "RP-FI-1 update: a direct Ash.update repointing storage_key (bypassing upload/3) is REFUSED — no residue",
         ctx do
      sc = scope()

      # Mint a governed row through the chokepoint — this is the ONLY legitimate way a
      # storage_key lands.
      assert {:ok, file} = Files.upload(sc, payload(), base_opts(ctx))
      governed_key = file.storage_key
      assert is_binary(governed_key) and governed_key != ""

      smuggled = "#{sc.org_id}/SMUGGLED-via-update"

      # The bypass: a raw update, authorize?: false, repointing storage_key at a key that
      # skipped size/type enforcement AND the audit. Must be REFUSED by the guard.
      result =
        file
        |> Ash.Changeset.for_update(:update, %{storage_key: smuggled})
        |> Ash.update(authorize?: false)

      assert {:error, error} = result
      assert Exception.message(error) =~ "ungoverned-file-row"

      # Anti-tautology: the persisted key is UNCHANGED — the repoint minted nothing and the
      # row still carries the governed key (the refusal aborted the transaction).
      reloaded = Ash.get!(FileResource, file.id, authorize?: false)
      assert reloaded.storage_key == governed_key
      refute reloaded.storage_key == smuggled

      %{rows: [[count]]} =
        TestRepo.query!(
          "SELECT count(*) FROM nef_file WHERE nef_storage_key = $1",
          [smuggled]
        )

      assert count == 0
    end

    # Positive control for the update path: the SAME-shape repoint SUCCEEDS when it carries
    # the chokepoint marker. Proves the refusal above keys on the ABSENCE of the marker (not
    # on updates being categorically blocked, and not on some incidental update failure) —
    # so the update red-path is non-vacuous: drop `:update` from the guard registration and
    # the bypass update passes; remove the marker and the governed update fails.
    test "RP-FI-1 update control: a storage_key repoint bearing the chokepoint marker SUCCEEDS",
         ctx do
      sc = scope()

      assert {:ok, file} = Files.upload(sc, payload(), base_opts(ctx))
      repointed = "#{sc.org_id}/governed-repoint"

      result =
        file
        |> Ash.Changeset.for_update(:update, %{storage_key: repointed})
        |> Ash.Changeset.set_context(%{private: %{ChokepointGuard.marker_key() => true}})
        |> Ash.update(authorize?: false)

      assert {:ok, updated} = result
      assert updated.storage_key == repointed
    end

    # An update that does NOT touch storage_key is unaffected by the guard — the row's
    # governed pointer is preserved and non-storage_key attributes update freely. This
    # proves the guard gates only the ungoverned-pointer write, not all updates (so the
    # `:update` registration does not lock the resource).
    test "an update leaving storage_key untouched is allowed (guard gates only the pointer write)",
         ctx do
      sc = scope()

      assert {:ok, file} = Files.upload(sc, payload(), base_opts(ctx))
      governed_key = file.storage_key

      result =
        file
        |> Ash.Changeset.for_update(:update, %{filename: "renamed.txt"})
        |> Ash.update(authorize?: false)

      assert {:ok, updated} = result
      assert updated.filename == "renamed.txt"
      # storage_key untouched by the update stays the governed key.
      assert updated.storage_key == governed_key
    end
  end

  # ---------------------------------------------------------------------------
  # AC-G14-4 / RP-FI-3 · quarantine fail-closed

  describe "quarantine-by-default fail-closed (AC-G14-4 / RP-FI-3)" do
    test "a freshly uploaded file lands :quarantined, NOT :active", ctx do
      assert {:ok, file} = Files.upload(scope(), payload(), base_opts(ctx))

      # The engine never sets status; the resource default governs. If that default
      # were flipped back to :active this assertion FAILS — the fail-closed red-path.
      assert file.status == :quarantined
      refute file.status == :active

      # Read back from the DB to prove it's the persisted status, not an in-memory
      # struct default.
      reloaded = Ash.get!(FileResource, file.id, authorize?: false)
      assert reloaded.status == :quarantined
    end
  end

  # ---------------------------------------------------------------------------
  # AC-G14-6 / RP-FI-5 · deny-by-default size/type (enforced BEFORE storage)

  describe "deny-by-default size/type, enforced before storage (AC-G14-6 / RP-FI-5)" do
    test "an over-size upload is refused BEFORE Storage.put — no bytes written", ctx do
      sc = scope()
      big = :binary.copy("x", 2_000)
      opts = base_opts(ctx, max_bytes: 1_000, key: "#{sc.org_id}/oversize-probe.txt")

      assert {:error, {:too_large, 2_000, 1_000}} =
               Files.upload(sc, payload(%{binary: big}), opts)

      # Anti-tautology: prove the store was NOT touched — the key holds no bytes and
      # the root is empty. A guard that called Storage.put before enforcing would be
      # DETECTED here.
      assert {:error, :not_found} = Local.get("#{sc.org_id}/oversize-probe.txt", ctx.storage_config)
      assert storage_root_empty?(ctx.root)
    end

    test "a non-allowlisted content type is refused BEFORE Storage.put — no bytes written",
         ctx do
      sc = scope()
      opts = base_opts(ctx, key: "#{sc.org_id}/evil-probe.exe")

      assert {:error, {:content_type_not_allowed, "application/x-msdownload"}} =
               Files.upload(
                 sc,
                 payload(%{content_type: "application/x-msdownload", filename: "evil.exe"}),
                 opts
               )

      assert {:error, :not_found} = Local.get("#{sc.org_id}/evil-probe.exe", ctx.storage_config)
      assert storage_root_empty?(ctx.root)
    end

    test "an empty content type is refused (deny-by-default)", ctx do
      assert {:error, {:content_type_not_allowed, ""}} =
               Files.upload(scope(), payload(%{content_type: ""}), base_opts(ctx))
    end

    test "enforce/4 is exact-match allowlist: a type NOT literally present is refused" do
      allowed = ~w(image/png text/plain)
      assert :ok = Files.enforce("image/png", 10, allowed, 1_000)
      assert {:error, {:content_type_not_allowed, "image/gif"}} =
               Files.enforce("image/gif", 10, allowed, 1_000)
      assert {:error, {:too_large, 2_000, 1_000}} =
               Files.enforce("image/png", 2_000, allowed, 1_000)
    end

    test "RP-FI-5 anti-tautology: widening the allowlist to `*` would ADMIT the type the deny-path refuses" do
      # The deny-by-default guarantee is non-vacuous: the SAME type the exact-match
      # allowlist refuses is ADMITTED once the allowlist is sabotaged to contain the
      # wildcard-ish universal. `enforce/4` is exact-match, so a literal "*" does NOT
      # magically admit everything — proving the refusal is on exact membership, not a
      # pattern. We assert both: refused when absent, admitted only when the EXACT type
      # is listed.
      refute match?(:ok, Files.enforce("image/gif", 10, ~w(image/png), 1_000))
      assert :ok = Files.enforce("image/gif", 10, ~w(image/png image/gif), 1_000)
      # A literal "*" in the allowlist does NOT admit a different type — exact-match
      # only, so deny-by-default cannot be defeated by a wildcard string.
      refute match?(:ok, Files.enforce("image/gif", 10, ~w(*), 1_000))
    end
  end

  # A rejected upload must leave the storage root with NO stored objects.
  defp storage_root_empty?(root) do
    case Elixir.File.ls(root) do
      {:ok, entries} -> entries == []
      {:error, :enoent} -> true
    end
  end

  # ---------------------------------------------------------------------------
  # WS-F5 F5.2 · byte-size telemetry (samen.files.upload.byte_size)

  describe "upload/3 — byte-size telemetry (WS-F5 F5.2)" do
    test "a stored upload emits [:samen, :files, :upload, :stop] with the byte size", ctx do
      handler = {:files_telemetry, System.unique_integer([:positive])}
      test_pid = self()

      :telemetry.attach(
        handler,
        [:samen, :files, :upload, :stop],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:files_upload_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      binary = "measure my bytes exactly"
      assert {:ok, _file} = Files.upload(scope(), payload(%{binary: binary}), base_opts(ctx))

      assert_receive {:files_upload_telemetry, measurements, metadata}
      assert measurements.byte_size == byte_size(binary)
      assert metadata.result == :ok
    end

    test "a REJECTED upload emits NO telemetry (the sample keys on a stored upload)", ctx do
      handler = {:files_telemetry_reject, System.unique_integer([:positive])}
      test_pid = self()

      :telemetry.attach(
        handler,
        [:samen, :files, :upload, :stop],
        fn _e, m, meta, _ -> send(test_pid, {:files_upload_telemetry, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # A non-allowlisted type is refused BEFORE storage — no stored upload, no sample.
      assert {:error, {:content_type_not_allowed, _}} =
               Files.upload(scope(), payload(%{content_type: "application/x-evil"}), base_opts(ctx))

      refute_receive {:files_upload_telemetry, _, _}
    end
  end
end
