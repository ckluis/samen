defmodule Samen.Backup.VerificationTest do
  @moduledoc """
  L6 / T92 — backup VERIFICATION ("did the backup actually work?").

  Two layers:

    * PURE-LOGIC gate + fail-honest contract (always run, deterministic). These are
      the sabotage targets: neuter the verifier into claiming `:ok` on a
      corrupt/missing/unconfigured backup and the named cases below flip red.
    * A REAL `pg_dump` → `pg_restore` round-trip into a scratch database
      (done-criteria #1): a clean dump verifies `:ok`; a CORRUPTED dump and a
      MISSING dump both FAIL — the refutable control proving the check has teeth.
  """
  use ExUnit.Case, async: false

  alias Samen.Backup.Verification
  alias Samen.Backup.Restore.{NotConfigured, LocalPgDump}

  # A stub restore target driven by an in-memory manifest, so the gate/alert logic
  # is tested without touching Postgres. `restore/2` returns a handle whose query
  # answers `manifest/2` from the configured map (keyed by the `FROM <table>` in
  # the generated SQL).
  defmodule StubRestore do
    @behaviour Samen.Backup.Restore
    @impl true
    def configured?(config), do: Map.get(config, :configured, true)

    @impl true
    def restore(%{restored: restored}, _scratch) do
      query = fn sql, _params ->
        [_, table] = Regex.run(~r/FROM (\w+) t/, sql)
        %{count: c, checksum: k} = Map.fetch!(restored, table)
        {:ok, %{rows: [[c, k]]}}
      end

      {:ok, %{query: query, cleanup: fn -> :ok end}}
    end

    def restore(%{restore_error: reason}, _scratch), do: {:error, reason}
  end

  defp expect(map), do: Map.new(map, fn {t, {c, k}} -> {t, %{count: c, checksum: k}} end)

  describe "pure gate — compare/2 fails closed" do
    test "identical manifests match" do
      m = expect(%{"a" => {3, "abc"}, "b" => {0, ""}})
      assert :ok == Verification.compare(m, m)
    end

    test "a short row count is a mismatch (a partial/corrupt restore)" do
      exp = expect(%{"a" => {3, "abc"}})
      got = expect(%{"a" => {2, "abc"}})
      assert {:mismatch, [{"a", %{expected: _, got: _}}]} = Verification.compare(exp, got)
    end

    test "a drifted checksum is a mismatch (content changed under an equal count)" do
      exp = expect(%{"a" => {3, "abc"}})
      got = expect(%{"a" => {3, "XYZ"}})
      assert {:mismatch, [{"a", _}]} = Verification.compare(exp, got)
    end

    test "a table missing from the restore is a mismatch" do
      exp = expect(%{"a" => {3, "abc"}, "b" => {1, "z"}})
      got = expect(%{"a" => {3, "abc"}})
      assert {:mismatch, [{"b", :missing_from_restore}]} = Verification.compare(exp, got)
    end
  end

  describe "verify/1 fail-honest contract" do
    test "unconfigured restore target returns {:error, :not_configured}, NEVER {:ok}" do
      assert {:error, :not_configured} =
               Verification.verify(adapter: NotConfigured, config: %{}, expected_manifest: %{})
    end

    test "a corrupt/missing artifact (restore step errors) surfaces as {:restore_failed, _}" do
      assert {:error, {:restore_failed, :artifact_gone}} =
               Verification.verify(
                 adapter: StubRestore,
                 config: %{restore_error: :artifact_gone},
                 expected_manifest: expect(%{"a" => {1, "x"}})
               )
    end

    test "a restore that does NOT match the manifest surfaces as {:verification_failed, _}" do
      assert {:error, {:verification_failed, diffs}} =
               Verification.verify(
                 adapter: StubRestore,
                 config: %{restored: %{"widget" => %{count: 2, checksum: "bad"}}},
                 expected_manifest: expect(%{"widget" => {5, "good"}})
               )

      assert [{"widget", %{expected: _, got: _}}] = diffs
    end

    test "a full matching round-trip returns {:ok, report}" do
      manifest = %{"widget" => %{count: 5, checksum: "good"}}

      assert {:ok, %{tables: 1}} =
               Verification.verify(
                 adapter: StubRestore,
                 config: %{restored: manifest},
                 expected_manifest: expect(%{"widget" => {5, "good"}})
               )
    end
  end

  describe "operator-plane alert (done-criteria #2)" do
    setup do
      ref = make_ref()

      :telemetry.attach(
        "bkp-fail-#{inspect(ref)}",
        [:samen, :backup, :verification, :failed],
        fn _event, meas, meta, pid -> send(pid, {:alert, meas, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("bkp-fail-#{inspect(ref)}") end)
      :ok
    end

    test "a failed verification raises the operator alert, token-blind (INV-2)" do
      assert {:error, {:verification_failed, _}} =
               Verification.verify(
                 adapter: StubRestore,
                 config: %{restored: %{"lead" => %{count: 0, checksum: ""}}},
                 expected_manifest: expect(%{"lead" => {9, "abc123"}})
               )

      assert_receive {:alert, %{count: 1}, meta}
      assert meta.kind == :verification_failed

      # Token-blind: the alert carries table names / counts / checksums only — no
      # vault token, no plaintext field value.
      refute inspect(meta) =~ "vt_"
    end

    test "an unconfigured target also raises the alert (never a silent green)" do
      assert {:error, :not_configured} =
               Verification.verify(adapter: NotConfigured, config: %{}, expected_manifest: %{})

      assert_receive {:alert, _, %{kind: :not_configured}}
    end
  end

  # --- REAL pg_dump → pg_restore round-trip (done-criteria #1) --------------------
  describe "real restore round-trip" do
    @src_db "samen_core_backup_src"
    @scratch_db "samen_core_backup_scratch"

    setup do
      unless LocalPgDump.configured?(%{dump_path: "x"}) do
        # pg tooling is a CLAUDE.md prerequisite; if genuinely absent, skip loudly.
        raise "pg_dump/pg_restore/createdb not available — required for L6 restore proof"
      end

      user = System.get_env("USER") || "postgres"
      dir = System.tmp_dir!()
      dump = Path.join(dir, "bkp_#{System.unique_integer([:positive])}.dump")

      # Build a real source DB with real rows.
      _ = System.cmd("dropdb", ["--if-exists", @src_db], stderr_to_stdout: true)
      {_, 0} = System.cmd("createdb", [@src_db], stderr_to_stdout: true)

      seed = """
      CREATE TABLE bkp_widget (id int primary key, label text);
      INSERT INTO bkp_widget VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d'),(5,'e');
      """

      {_, 0} = System.cmd("psql", ["-d", @src_db, "-v", "ON_ERROR_STOP=1", "-c", seed], stderr_to_stdout: true)

      # Expected manifest computed from the PRIMARY (source) — captured at backup time.
      {:ok, src} = Postgrex.start_link(hostname: "localhost", username: user, database: @src_db)
      expected = Verification.manifest(%{query: fn s, p -> q(src, s, p) end}, ["bkp_widget"])
      GenServer.stop(src)

      {_, 0} = System.cmd("pg_dump", ["-Fc", "-f", dump, @src_db], stderr_to_stdout: true)

      on_exit(fn ->
        File.rm(dump)
        System.cmd("dropdb", ["--if-exists", @src_db], stderr_to_stdout: true)
        System.cmd("dropdb", ["--if-exists", @scratch_db], stderr_to_stdout: true)
      end)

      %{dump: dump, expected: expected, user: user}
    end

    test "a CLEAN dump restores into a scratch DB and verifies :ok", %{dump: dump, expected: exp} do
      assert {:ok, %{tables: 1}} =
               Verification.verify(
                 adapter: LocalPgDump,
                 config: %{dump_path: dump, scratch_database: @scratch_db},
                 expected_manifest: exp
               )
    end

    test "a CORRUPTED dump FAILS verification (refutable control)", %{dump: dump, expected: exp} do
      corrupt = dump <> ".corrupt"
      File.cp!(dump, corrupt)
      # Truncate to the first 128 bytes — a torn artifact pg_restore cannot load.
      {:ok, fd} = File.open(corrupt, [:read, :write])
      data = IO.binread(fd, 128)
      File.close(fd)
      File.write!(corrupt, data)
      on_exit(fn -> File.rm(corrupt) end)

      assert {:error, reason} =
               Verification.verify(
                 adapter: LocalPgDump,
                 config: %{dump_path: corrupt, scratch_database: @scratch_db},
                 expected_manifest: exp
               )

      assert match?({:restore_failed, _}, reason) or match?({:verification_failed, _}, reason)
    end

    test "a MISSING dump artifact FAILS verification", %{expected: exp} do
      assert {:error, {:restore_failed, {:artifact_missing, _}}} =
               Verification.verify(
                 adapter: LocalPgDump,
                 config: %{dump_path: "/nonexistent/nope.dump", scratch_database: @scratch_db},
                 expected_manifest: exp
               )
    end
  end

  defp q(pid, sql, params) do
    case Postgrex.query(pid, sql, params) do
      {:ok, res} -> {:ok, %{rows: res.rows}}
      other -> other
    end
  end
end
