defmodule Samen.AudEventDefaultPartitionTest do
  @moduledoc """
  ARCH-9 — the partition time-bomb CLASS, not only its one instance (#119 fixed the calendar-month roll-forward).

  A row whose `aud_occurred_at` is in no partition used to hard-fail the audited write, and audited writes are
  audit-or-refuse, so the failure blocked the business action. Proven here, each with a positive control:

    1. the mechanism: without a DEFAULT partition an out-of-window insert fails; with one it lands there;
    2. a row in DEFAULT is REPORTED (log line + telemetry), an in-window row is not;
    3. creating a monthly partition over rows that sit in DEFAULT moves them (Postgres refuses otherwise), in one
       transaction, losing nothing — also with a real commit (`Samen.TestSandbox.auto!/1`);
    4. the runway: per table, warning below a month, critical at zero/negative, unknown (never ok) when unreadable;
    5. the roll-forward job fails (is retried) when a month could not be created;
    6. `occurred_at` at the Writer chokepoint: a future time is clamped, a past one kept, nothing rejected;
    7. the move under REAL concurrent writers (a second connection, committed writes): it completes, loses and
       duplicates nothing, and a held conflicting lock makes it fail fast with `lock_not_available`;
    8. the landing test cannot abort the caller's transaction (25P02), and needs no query per write;
    9. the runway only reads the tables it understands, and says UNKNOWN (naming the table) otherwise.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SamenCore.TestRepo, as: Repo
  alias Samen.AuditChain.Writer
  alias Samen.AuditEvent
  alias Samen.AuditEvent.PartitionManager

  setup context do
    # a `@tag :commit` test runs in `:auto` mode itself (real commits): it must not also own a sandbox
    unless context[:commit], do: Samen.TestSandbox.shared!(Repo)
    # the in-memory partition bounds are per repo and outlive a test; a rolled-back DDL must not leak into the next
    PartitionManager.invalidate_bounds(Repo)
    on_exit(fn -> PartitionManager.invalidate_bounds(Repo) end)
    :ok
  end

  # A repo whose catalog cannot be read (an outage): `query` fails, the way Postgrex reports it.
  defmodule DownRepo do
    def query(_sql, _params \\ []), do: {:error, %DBConnection.ConnectionError{message: "down"}}
  end

  defp in_default(subject) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM ONLY aud_event_default WHERE aud_subject_id = $1", [subject])

    n
  end

  defp in_partition(name, subject) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{name} WHERE aud_subject_id = $1", [subject])
    n
  end

  defp insert!(subject, at) do
    {:ok, row} = AuditEvent.insert(Repo, %{event_type: "system", subject_id: subject, occurred_at: at})
    row
  end

  defp catch_events(events) do
    me = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach_many(id, events, fn name, meas, meta, _ -> send(me, {:telemetry, name, meas, meta}) end, nil)
    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "the mechanism: an insert outside every partition" do
    test "WITHOUT a DEFAULT partition it fails (the class of bug); with one it lands there" do
      Repo.query!("DROP TABLE aud_event_default")

      assert_raise Postgrex.Error, ~r/no partition/i, fn ->
        AuditEvent.insert(Repo, %{event_type: "system", subject_id: "a", occurred_at: ~U[1999-05-05 05:00:00Z]})
      end
    end

    test "WITH the DEFAULT partition the same insert succeeds and sits in it; an in-window row does not" do
      subject = "default-#{System.unique_integer([:positive])}"
      row = insert!(subject, ~U[1999-05-05 05:00:00Z])
      assert row.subject_id == subject
      assert in_default(subject) == 1

      # positive control: a row in a real month is NOT in DEFAULT
      current = "current-#{System.unique_integer([:positive])}"
      insert!(current, DateTime.utc_now())
      assert in_default(current) == 0
    end
  end

  describe "a row in the DEFAULT partition is reported, loudly" do
    test "log line + telemetry carry no row value; an in-window row reports nothing" do
      catch_events([[:samen, :audit, :partition, :default_landing]])
      subject = "loud-#{System.unique_integer([:positive])}"

      log = capture_log(fn -> insert!(subject, ~U[1999-06-06 06:00:00Z]) end)

      assert log =~ "audit_event_in_default_partition"
      refute log =~ subject
      refute log =~ "1999"
      assert_received {:telemetry, [:samen, :audit, :partition, :default_landing], %{count: 1}, %{table: "aud_event"}}

      # positive control: nothing is reported for a row in a monthly partition
      log = capture_log(fn -> insert!("quiet-#{System.unique_integer([:positive])}", DateTime.utc_now()) end)
      refute log =~ "audit_event_in_default_partition"
      refute_received {:telemetry, [:samen, :audit, :partition, :default_landing], _, _}
    end

    test "an audited Writer.write far in the past SUCCEEDS (not blocked), chain entry included, and is reported" do
      catch_events([[:samen, :audit, :partition, :default_landing]])
      org = "org-#{System.unique_integer([:positive])}"
      subject = "past-#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert {:ok, %{aud_event: aud, chain: chain}} =
                   Writer.write(Repo, %{
                     org_id: org,
                     event_type: "break_glass",
                     subject_id: subject,
                     actor_id: "actor",
                     detail: "event=deferred",
                     occurred_at: ~U[1999-01-01 00:00:00Z]
                   })

          assert aud.occurred_at == ~U[1999-01-01 00:00:00.000000Z]
          assert chain != :skipped
        end)

      assert in_default(subject) == 1
      assert log =~ "audit_event_in_default_partition"
      assert_received {:telemetry, [:samen, :audit, :partition, :default_landing], _, _}
    end
  end

  describe "PartitionManager.ensure_partition/2 over rows in DEFAULT" do
    test "Postgres itself refuses the plain CREATE (why the manager must move rows)" do
      insert!("refuse-#{System.unique_integer([:positive])}", ~U[1997-03-10 00:00:00Z])
      name = PartitionManager.partition_name(~D[1997-03-01])
      {_, from_ts, to_ts} = PartitionManager.partition_spec(~D[1997-03-01])

      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query(
                 "CREATE TABLE #{name} PARTITION OF aud_event FOR VALUES FROM ('#{from_ts}') TO ('#{to_ts}')",
                 [],
                 mode: :savepoint
               )
    end

    test "rows of the new month move into it; other months' rows stay in DEFAULT; nothing is lost" do
      tag = System.unique_integer([:positive])
      march = "march-#{tag}"
      march2 = "march2-#{tag}"
      may = "may-#{tag}"
      march_row = insert!(march, ~U[1997-03-10 10:00:00Z])
      insert!(march2, ~U[1997-03-31 23:59:59Z])
      insert!(may, ~U[1997-05-10 10:00:00Z])
      assert in_default(march) == 1

      %{rows: [[total_before]]} = Repo.query!("SELECT count(*) FROM aud_event")
      name = PartitionManager.partition_name(~D[1997-03-01])

      capture_log(fn -> assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[1997-03-01]) end)

      assert in_partition(name, march) == 1
      assert in_partition(name, march2) == 1
      assert in_default(march) == 0
      assert in_default(may) == 1

      %{rows: [[total_after]]} = Repo.query!("SELECT count(*) FROM aud_event")
      assert total_after == total_before

      # identity survives the move
      assert [%{id: id, occurred_at: at}] = AuditEvent.for_subject(Repo, march)
      assert id == march_row.id and at == march_row.occurred_at

      # a second month moves the same way (the set-aside name and index names do not collide)
      may_name = PartitionManager.partition_name(~D[1997-05-01])
      capture_log(fn -> assert {:ok, ^may_name} = PartitionManager.ensure_partition(Repo, ~D[1997-05-01]) end)
      assert in_partition(may_name, may) == 1
      assert in_default(may) == 0

      # idempotent, and the DEFAULT partition is still attached and still catches
      assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[1997-03-01])
      late = "late-#{tag}"
      insert!(late, ~U[1997-08-08 00:00:00Z])
      assert in_default(late) == 1
    end

    test "positive control: with nothing in DEFAULT for the month it is a plain create, other rows untouched" do
      tag = System.unique_integer([:positive])
      other = "other-#{tag}"
      insert!(other, ~U[1997-09-09 09:00:00Z])
      name = PartitionManager.partition_name(~D[1997-07-01])

      log = capture_log(fn -> assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[1997-07-01]) end)

      refute log =~ "moved rows"
      assert in_default(other) == 1
    end

    test "a database without a DEFAULT partition (not yet migrated) still rolls forward" do
      Repo.query!("DROP TABLE aud_event_default")
      name = PartitionManager.partition_name(~D[1997-11-01])
      assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[1997-11-01])
    end

    @tag :commit
    test "the move also works with a real COMMIT (auto mode), and loses no row" do
      Samen.TestSandbox.auto!(Repo)
      tag = System.unique_integer([:positive])
      subject = "commit-#{tag}"
      name = PartitionManager.partition_name(~D[1996-04-01])

      on_exit(fn ->
        Repo.query("DROP TABLE IF EXISTS #{name}")
        # the committed DEFAULT row goes with a TRUNCATE (the append-only trigger is row-level)
        Repo.query("TRUNCATE aud_event_default")
      end)

      insert!(subject, ~U[1996-04-04 04:00:00Z])
      assert in_default(subject) == 1

      capture_log(fn -> assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[1996-04-01]) end)

      # a SECOND connection sees only committed data: the row is in the new partition, committed
      {from_other_connection, default_other} =
        Task.async(fn ->
          {in_partition(name, subject), in_default(subject)}
        end)
        |> Task.await()

      assert from_other_connection == 1 and default_other == 0
    end
  end

  # ------------------------------------------------------------------------------------------------------------
  # The move under real concurrency (committed writes from other connections)
  # ------------------------------------------------------------------------------------------------------------

  describe "the move under concurrent writers (real connections, real commits)" do
    @describetag :commit

    setup do
      Samen.TestSandbox.auto!(Repo)
      :ok
    end

    defp cleanup_months!(dates) do
      on_exit(fn ->
        for d <- dates, do: Repo.query("DROP TABLE IF EXISTS #{PartitionManager.partition_name(d)}")
        Repo.query("DROP TABLE IF EXISTS aud_event_move_month, aud_event_move_default")
        Repo.query("TRUNCATE aud_event_default")
      end)
    end

    defp ids_like(prefix) do
      %{rows: rows} = Repo.query!("SELECT aud_id::text FROM aud_event WHERE aud_subject_id LIKE $1", [prefix <> "%"])
      Enum.map(rows, fn [id] -> id end)
    end

    # A second connection that has INSERTED a row (into DEFAULT) and not committed: it holds ROW EXCLUSIVE on
    # aud_event, which conflicts with the move's exclusive lock. Released by a message, never a sleep.
    defp hold_uncommitted_writer(subject, at) do
      test = self()

      task =
        Task.async(fn ->
          Repo.transaction(fn ->
            row = insert!(subject, at)
            send(test, {:held, row.id})

            receive do
              :release -> row.id
            end
          end)
        end)

      receive do
        {:held, id} -> {task, id}
      end
    end

    # Wait (on the observed state, bounded) until some backend waits for an ACCESS EXCLUSIVE lock on aud_event: the
    # move has finished staging and is queued for its exclusive window.
    defp wait_for_exclusive_waiter(deadline \\ System.monotonic_time(:millisecond) + 15_000) do
      %{rows: [[waiting?]]} =
        Repo.query!(
          "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'relation' AND relation = 'aud_event'::regclass " <>
            "AND mode = 'AccessExclusiveLock' AND NOT granted)"
        )

      cond do
        waiting? -> :ok
        System.monotonic_time(:millisecond) > deadline -> flunk("the move never reached its exclusive window")
        true -> Process.sleep(5) && wait_for_exclusive_waiter(deadline)
      end
    end

    test "a row committed AFTER the staging copy is taken by the top-up under the lock: nothing lost, none duplicated" do
      cleanup_months!([~D[1995-02-01]])
      tag = System.unique_integer([:positive])
      prefix = "topup-#{tag}-"
      for i <- 1..3, do: insert!("#{prefix}seed#{i}", ~U[1995-02-10 10:00:00Z])
      other = insert!("#{prefix}other", ~U[1995-07-10 10:00:00Z])

      # a writer in flight: its row is in DEFAULT, uncommitted, and holds the lock the move needs
      {holder, held_id} = hold_uncommitted_writer("#{prefix}held", ~U[1995-02-20 10:00:00Z])

      mover = Task.async(fn -> PartitionManager.ensure_partition(Repo, ~D[1995-02-01]) end)
      wait_for_exclusive_waiter()

      # staging has run and could not see the uncommitted row; now it commits and the move proceeds
      send(holder.pid, :release)
      assert {:ok, ^held_id} = Task.await(holder)
      name = PartitionManager.partition_name(~D[1995-02-01])
      capture_log(fn -> assert {:ok, ^name} = Task.await(mover, 30_000) end)

      ids = ids_like(prefix)
      assert length(ids) == 5 and length(Enum.uniq(ids)) == 5
      assert held_id in ids and other.id in ids

      # the in-range ones (seeds + the late committer) are in the month; the July row stays in DEFAULT
      assert in_partition(name, "#{prefix}held") == 1
      assert in_partition(name, "#{prefix}seed1") == 1
      assert in_default("#{prefix}other") == 1
      assert in_default("#{prefix}held") == 0
    end

    test "a second connection writing continuously while the move runs: it completes, ids match, later rows are queryable" do
      cleanup_months!([~D[1995-03-01]])
      tag = System.unique_integer([:positive])
      prefix = "cw-#{tag}-"
      seeded = for i <- 1..5, do: insert!("#{prefix}seed#{i}", ~U[1995-03-05 05:00:00Z]).id
      test = self()

      writer =
        Task.async(fn ->
          loop = fn loop, n, acc ->
            receive do
              :stop -> acc
            after
              0 ->
                row = insert!("#{prefix}w#{n}", ~U[1995-03-15 05:00:00Z])
                send(test, {:wrote, n})
                loop.(loop, n + 1, [row.id | acc])
            end
          end

          loop.(loop, 0, [])
        end)

      # at least 3 writes landed before the move starts (a message, not a sleep) ...
      assert_receive {:wrote, 2}, 10_000

      name = PartitionManager.partition_name(~D[1995-03-01])
      capture_log(fn -> assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[1995-03-01]) end)

      # ... and at least 3 more after it finished
      last = Stream.repeatedly(fn -> receive do {:wrote, n} -> n after 0 -> nil end end) |> Enum.take_while(& &1) |> List.last()
      target = (last || 2) + 3
      assert_receive {:wrote, ^target}, 10_000

      send(writer.pid, :stop)
      written = Task.await(writer, 10_000)

      ids = ids_like(prefix)
      assert Enum.sort(ids) == Enum.sort(seeded ++ written)
      assert length(Enum.uniq(ids)) == length(ids)

      # rows written after the move are in the new partition and visible through the parent
      %{rows: [[after_move]]} = Repo.query!("SELECT count(*) FROM #{name} WHERE aud_subject_id LIKE $1", [prefix <> "w%"])
      assert after_move >= 3
      assert in_default(prefix <> "seed1") == 0
    end

    test "a held conflicting lock makes the move fail FAST with lock_not_available, rolled back whole, writers not queued" do
      cleanup_months!([~D[1995-04-01]])
      prev = Application.get_env(:samen_core, :partition_move_lock_timeout_ms)
      Application.put_env(:samen_core, :partition_move_lock_timeout_ms, 300)

      on_exit(fn ->
        if prev, do: Application.put_env(:samen_core, :partition_move_lock_timeout_ms, prev), else: Application.delete_env(:samen_core, :partition_move_lock_timeout_ms)
      end)

      tag = System.unique_integer([:positive])
      prefix = "lt-#{tag}-"
      seeded = insert!("#{prefix}seed", ~U[1995-04-10 10:00:00Z])
      {holder, _} = hold_uncommitted_writer("#{prefix}held", ~U[1995-04-11 10:00:00Z])

      started = System.monotonic_time(:millisecond)

      log =
        capture_log(fn ->
          assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
                   PartitionManager.ensure_partition(Repo, ~D[1995-04-01])
        end)

      assert System.monotonic_time(:millisecond) - started < 5_000
      # loud and value-free
      assert log =~ "audit_partition_move"
      refute log =~ prefix

      # nothing half-done: no staging tables, no month, the row still in DEFAULT
      assert Repo.query!("SELECT to_regclass('aud_event_move_month') IS NULL AND to_regclass($1) IS NULL", ["public." <> PartitionManager.partition_name(~D[1995-04-01])]).rows == [[true]]
      assert in_default("#{prefix}seed") == 1

      # the failed move left no lock behind: another writer is not queued
      other = Task.async(fn -> insert!("#{prefix}other", ~U[1995-04-12 10:00:00Z]) end)
      assert %{} = Task.await(other, 5_000)

      # once the conflicting writer is gone, the retry (what Oban does) succeeds and moves everything
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder)
      Application.delete_env(:samen_core, :partition_move_lock_timeout_ms)
      name = PartitionManager.partition_name(~D[1995-04-01])
      capture_log(fn -> assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[1995-04-01]) end)
      assert length(ids_like(prefix)) == 3
      assert in_partition(name, "#{prefix}seed") == 1
      assert seeded.id in ids_like(prefix)
    end

    test "a probe behind the move's exclusive lock fails fast instead of waiting (the /readyz read)" do
      test = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!("LOCK TABLE aud_event_default IN ACCESS EXCLUSIVE MODE")
            send(test, :locked)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :locked, 10_000
      started = System.monotonic_time(:millisecond)
      assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} = PartitionManager.runway(Repo, lock_timeout_ms: 200)
      assert System.monotonic_time(:millisecond) - started < 3_000

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder)
      # positive control: the same read succeeds once the lock is gone
      assert {:ok, [_]} = PartitionManager.runway(Repo, lock_timeout_ms: 200)
    end
  end

  # ------------------------------------------------------------------------------------------------------------
  # The landing test: no abort of the caller's transaction, no query per write
  # ------------------------------------------------------------------------------------------------------------

  describe "the default-landing test cannot poison the caller's transaction" do
    # Delegates to the real repo, except the partition-bounds read, which is a REAL Postgres error (division by
    # zero) taken with the options it was given — exactly what a failing catalog query would do.
    defmodule FaultRepo do
      def insert(cs), do: SamenCore.TestRepo.insert(cs)

      def query(sql, params \\ [], opts \\ []) do
        if String.contains?(sql, "relpartbound"),
          do: SamenCore.TestRepo.query("SELECT 1/0", [], opts),
          else: SamenCore.TestRepo.query(sql, params, opts)
      end
    end

    test "a failing bounds read is reported and the transaction (and the audited write) survive; 25P02 does not occur" do
      PartitionManager.invalidate_bounds(FaultRepo)

      log =
        capture_log(fn ->
          assert {:ok, {:ok, row}} =
                   Repo.transaction(fn ->
                     result = AuditEvent.insert(FaultRepo, %{event_type: "system", subject_id: "fault", occurred_at: DateTime.utc_now()})
                     # the transaction is still usable: with a poisoned one this raises 25P02
                     assert %{rows: [[1]]} = Repo.query!("SELECT 1")
                     result
                   end)

          send(self(), {:row, row})
        end)

      assert_received {:row, row}
      assert log =~ "audit_default_landing_probe"
      assert in_partition(PartitionManager.partition_name(Date.utc_today()), "fault") == 1
      assert row.subject_id == "fault"
    end

    # Delegates to the real repo and tells the test whenever the partition catalog is read.
    defmodule CountingRepo do
      def insert(cs), do: SamenCore.TestRepo.insert(cs)

      def query(sql, params \\ [], opts \\ []) do
        if String.contains?(sql, "relpartbound"), do: send(Process.get(:bounds_probe_pid), :bounds_read)
        SamenCore.TestRepo.query(sql, params, opts)
      end
    end

    test "while the bounds are fresh a write issues no catalog query; they are read again after invalidation" do
      Process.put(:bounds_probe_pid, self())
      PartitionManager.invalidate_bounds(CountingRepo)
      write = fn -> {:ok, _} = AuditEvent.insert(CountingRepo, %{event_type: "system", subject_id: "cnt", occurred_at: DateTime.utc_now()}) end

      write.()
      assert_received :bounds_read

      write.()
      write.()
      refute_received :bounds_read

      PartitionManager.invalidate_bounds(CountingRepo)
      write.()
      assert_received :bounds_read
    end

    # The bounds read fails (a real Postgres error) when the calling process says so.
    defmodule ToggleRepo do
      def query(sql, params \\ [], opts \\ []) do
        if String.contains?(sql, "relpartbound") and Process.get(:bounds_fail),
          do: SamenCore.TestRepo.query("SELECT 1/0", [], opts),
          else: SamenCore.TestRepo.query(sql, params, opts)
      end
    end

    test "past its TTL the bounds are read again; a failing re-read is an error, never the stale ranges" do
      PartitionManager.invalidate_bounds(ToggleRepo)
      assert {:ok, ranges} = PartitionManager.partition_bounds(ToggleRepo)
      assert ranges != []

      Process.put(:bounds_fail, true)
      # within the TTL the cached ranges answer (the failing read is not even attempted)
      assert {:ok, ^ranges} = PartitionManager.partition_bounds(ToggleRepo)

      Application.put_env(:samen_core, :partition_bounds_ttl_ms, 0)
      on_exit(fn -> Application.delete_env(:samen_core, :partition_bounds_ttl_ms) end)
      assert {:error, %Postgrex.Error{}} = PartitionManager.partition_bounds(ToggleRepo)

      # positive control: the read works again once the fault is gone
      Process.put(:bounds_fail, false)
      assert {:ok, ^ranges} = PartitionManager.partition_bounds(ToggleRepo)
    end

    test "classification is right at the edges: a row in a covered month is not DEFAULT, a gap and the far future are" do
      {:ok, [{lo, _hi} | _] = ranges} = PartitionManager.partition_bounds(Repo)
      assert length(ranges) >= 3
      assert {:ok, false} = PartitionManager.lands_in_default?(Repo, lo)
      assert {:ok, true} = PartitionManager.lands_in_default?(Repo, DateTime.add(lo, -1, :second))
      assert {:ok, true} = PartitionManager.lands_in_default?(Repo, ~U[2099-01-01 00:00:00Z])
    end
  end

  describe "direct AuditEvent.insert callers are clamped too (the chokepoint, not only the Writer)" do
    test "a far-future occurred_at passed straight to insert/2 is clamped, claimed in detail, reported" do
      catch_events([[:samen, :audit, :occurred_at, :clamped]])
      future = DateTime.add(DateTime.utc_now(), 400 * 86_400)

      log =
        capture_log(fn ->
          {:ok, row} = AuditEvent.insert(Repo, %{event_type: "system", subject_id: "direct", detail: "event=y", occurred_at: future})
          send(self(), {:row, row})
        end)

      assert_received {:row, row}
      assert DateTime.diff(DateTime.utc_now(), row.occurred_at, :second) in 0..5
      assert row.detail =~ "event=y" and row.detail =~ "occurred_at_claimed="
      assert log =~ "audit_occurred_at_clamped"
      assert_received {:telemetry, [:samen, :audit, :occurred_at, :clamped], %{count: 1}, _}
      assert in_default("direct") == 0

      # positive control: a time inside the skew is kept as given, detail untouched
      soon = DateTime.add(DateTime.utc_now(), 60) |> DateTime.truncate(:microsecond)
      {:ok, kept} = AuditEvent.insert(Repo, %{event_type: "system", subject_id: "direct2", detail: "event=z", occurred_at: soon})
      assert kept.occurred_at == soon and kept.detail == "event=z"
    end
  end

  describe "runway/2" do
    test "healthy: the test database is two months ahead; nothing in DEFAULT" do
      Repo.query!("TRUNCATE aud_event_default")
      assert {:ok, [row]} = PartitionManager.runway(Repo)
      assert row.table == "aud_event"
      assert row.runway_days > 31
      assert row.status == :ok and row.reasons == []
      assert row.default_partition? and row.default_rows == 0
    end

    test "below one month is a WARNING; zero or negative is CRITICAL; the boundary is exact" do
      {:ok, [healthy]} = PartitionManager.runway(Repo)
      edge = healthy.covered_until

      warn_now = DateTime.add(edge, -10 * 86_400)
      assert {:ok, [row]} = PartitionManager.runway(Repo, now: warn_now)
      assert row.runway_days == 10 and row.status == :warn and :runway_low in row.reasons

      assert {:ok, [row]} = PartitionManager.runway(Repo, now: DateTime.add(edge, -31 * 86_400))
      assert row.runway_days == 31 and :runway_low not in row.reasons

      assert {:ok, [row]} = PartitionManager.runway(Repo, now: DateTime.add(edge, -30 * 86_400))
      assert row.runway_days == 30 and :runway_low in row.reasons

      assert {:ok, [row]} = PartitionManager.runway(Repo, now: DateTime.add(edge, 5 * 86_400))
      assert row.runway_days < 0 and row.status == :critical and :runway_critical in row.reasons

      assert {:ok, [row]} = PartitionManager.runway(Repo, now: DateTime.add(edge, -1800))
      assert row.runway_days == 0 and row.status == :critical
    end

    test "a hole at now (a later partition exists, the current one does not) is zero runway, not healthy" do
      PartitionManager.ensure_partition(Repo, ~D[2096-06-01])
      assert {:ok, [row]} = PartitionManager.runway(Repo, now: ~U[2060-01-01 00:00:00Z])
      assert row.runway_days == 0 and row.status == :critical
    end

    test "rows in DEFAULT and a missing DEFAULT partition are warnings; each is its own reason" do
      Repo.query!("TRUNCATE aud_event_default")
      insert!("runway-default-#{System.unique_integer([:positive])}", ~U[1999-01-01 00:00:00Z])

      assert {:ok, [row]} = PartitionManager.runway(Repo)
      assert row.default_rows == 1 and row.status == :warn and row.reasons == [:default_rows]

      Repo.query!("DROP TABLE aud_event_default")
      assert {:ok, [row]} = PartitionManager.runway(Repo)
      refute row.default_partition?
      assert row.status == :warn and row.reasons == [:no_default_partition]
    end

    test "UNKNOWN when the catalog cannot be read: an error, never an ok row; telemetry says so" do
      catch_events([[:samen, :audit, :partition, :runway_unknown], [:samen, :audit, :partition, :runway]])

      result = PartitionManager.runway(DownRepo)
      assert {:error, %DBConnection.ConnectionError{}} = result

      PartitionManager.emit_runway(result)
      assert_received {:telemetry, [:samen, :audit, :partition, :runway_unknown], %{count: 1}, _}
      refute_received {:telemetry, [:samen, :audit, :partition, :runway], _, _}

      # positive control: a readable runway emits the gauge, not the unknown series
      PartitionManager.emit_runway(PartitionManager.runway(Repo))
      assert_received {:telemetry, [:samen, :audit, :partition, :runway], %{runway_days: days}, %{table: "aud_event", status: :ok}}
      assert days > 31
      refute_received {:telemetry, [:samen, :audit, :partition, :runway_unknown], _, _}
    end
  end

  describe "runway/2 only reads the tables it understands" do
    test "no time-partitioned table at all is UNKNOWN, not an empty ok" do
      Repo.query!("DROP TABLE aud_event CASCADE")
      assert {:error, :no_partitioned_table} = PartitionManager.runway(Repo)
    end

    test "an integer-partitioned table is ignored: the runway of aud_event is still read (positive control above)" do
      Repo.query!("CREATE TABLE tmp_int_range (id integer) PARTITION BY RANGE (id)")
      Repo.query!("CREATE TABLE tmp_int_range_p PARTITION OF tmp_int_range FOR VALUES FROM (MINVALUE) TO (100)")
      Repo.query!("CREATE TABLE tmp_int_range_q PARTITION OF tmp_int_range FOR VALUES FROM (100) TO (MAXVALUE)")

      assert {:ok, rows} = PartitionManager.runway(Repo)
      assert Enum.map(rows, & &1.table) == ["aud_event"]
    end

    test "a time-partitioned table with a bound it cannot read is UNKNOWN and names the table" do
      Repo.query!("CREATE TABLE tmp_time_range (at timestamptz NOT NULL) PARTITION BY RANGE (at)")
      Repo.query!("CREATE TABLE tmp_time_range_p PARTITION OF tmp_time_range FOR VALUES FROM (MINVALUE) TO (MAXVALUE)")

      assert {:error, {:unreadable_partition_bound, "tmp_time_range"}} = PartitionManager.runway(Repo)
    end
  end

  describe "the migration's down will not destroy audit rows" do
    test "every host migration's down runs the guard before the DROP" do
      root = Path.expand("../..", __DIR__)
      files = Path.wildcard(root <> "/*/priv/*/migrations/20261114120000_aud_event_default_partition.exs")
      assert length(files) >= 5

      for f <- files do
        [_up, down] = String.split(File.read!(f), "def down do")
        guard = :binary.match(down, "default_partition_down_guard_sql()")
        drop = :binary.match(down, "DROP TABLE IF EXISTS aud_event_default")
        assert guard != :nomatch and drop != :nomatch and elem(guard, 0) < elem(drop, 0), f
      end
    end

    test "the guard RAISES while the DEFAULT partition holds rows, and the rows survive" do
      Repo.query!("TRUNCATE aud_event_default")
      insert!("down-#{System.unique_integer([:positive])}", ~U[1999-01-01 00:00:00Z])

      assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
               Repo.query(PartitionManager.default_partition_down_guard_sql(), [], mode: :savepoint)

      assert message =~ "holds audit rows that are in no monthly partition"
      assert Repo.query!("SELECT count(*) FROM ONLY aud_event_default").rows == [[1]]
    end

    test "positive controls: an empty DEFAULT passes the guard, and so does an absent one" do
      Repo.query!("TRUNCATE aud_event_default")
      assert {:ok, _} = Repo.query(PartitionManager.default_partition_down_guard_sql())
      Repo.query!("DROP TABLE aud_event_default")
      assert {:ok, _} = Repo.query(PartitionManager.default_partition_down_guard_sql())
    end
  end

  describe "the roll-forward job" do
    setup do
      prev = Application.get_env(:samen_core, :aud_event_repo)
      on_exit(fn -> if prev, do: Application.put_env(:samen_core, :aud_event_repo, prev), else: Application.delete_env(:samen_core, :aud_event_repo) end)
      :ok
    end

    test "perform/1 FAILS (so Oban retries and the discard is visible) when a month could not be created" do
      Application.put_env(:samen_core, :aud_event_repo, DownRepo)

      capture_log(fn ->
        assert {:error, {:partition_roll_forward_failed, n}} = PartitionManager.perform(%Oban.Job{args: %{}})
        assert n == 3
      end)
    end

    test "positive control: with a working repo it is :ok and emits the runway gauge" do
      Application.put_env(:samen_core, :aud_event_repo, Repo)
      catch_events([[:samen, :audit, :partition, :runway]])
      assert :ok = PartitionManager.perform(%Oban.Job{args: %{}})
      assert_received {:telemetry, [:samen, :audit, :partition, :runway], _, %{table: "aud_event"}}
    end
  end

  describe "occurred_at at the Writer chokepoint" do
    defp write(attrs) do
      org = "org-#{System.unique_integer([:positive])}"

      Writer.write(
        Repo,
        Map.merge(%{org_id: org, event_type: "reveal", subject_id: "s-#{System.unique_integer([:positive])}", actor_id: "a", detail: "event=x"}, attrs)
      )
    end

    test "a far-future occurred_at is CLAMPED to the write time, the claim kept in detail, and the write succeeds" do
      catch_events([[:samen, :audit, :occurred_at, :clamped]])
      future = DateTime.add(DateTime.utc_now(), 400 * 86_400)

      log = capture_log(fn -> assert {:ok, %{aud_event: aud, chain: chain}} = write(%{occurred_at: future}) ; send(self(), {:res, aud, chain}) end)
      assert_received {:res, aud, chain}

      assert DateTime.diff(DateTime.utc_now(), aud.occurred_at, :second) in 0..5
      assert aud.detail =~ "occurred_at_claimed=#{DateTime.to_iso8601(DateTime.truncate(future, :microsecond))}"
      assert aud.detail =~ "event=x"
      # the chain commits what the row says: the clamped time and the detail with the claim
      assert chain.occurred_at == aud.occurred_at
      assert chain.detail == aud.detail
      assert log =~ "audit_occurred_at_clamped"
      refute log =~ DateTime.to_iso8601(future)
      assert_received {:telemetry, [:samen, :audit, :occurred_at, :clamped], %{count: 1}, _}
    end

    test "within the skew a future time is kept untouched (positive control); past times are kept at any age" do
      catch_events([[:samen, :audit, :occurred_at, :clamped]])
      soon = DateTime.add(DateTime.utc_now(), 60) |> DateTime.truncate(:microsecond)
      assert {:ok, %{aud_event: aud}} = write(%{occurred_at: soon})
      assert aud.occurred_at == soon
      assert aud.detail == "event=x"

      thirty_days_ago = DateTime.add(DateTime.utc_now(), -30 * 86_400) |> DateTime.truncate(:microsecond)
      assert {:ok, %{aud_event: aud, chain: chain}} = write(%{occurred_at: thirty_days_ago})
      assert aud.occurred_at == thirty_days_ago and aud.detail == "event=x"
      # the true write time is on the chain row
      assert DateTime.diff(DateTime.utc_now(), chain.inserted_at, :second) in 0..5

      refute_received {:telemetry, [:samen, :audit, :occurred_at, :clamped], _, _}
    end

    test "the skew is configurable and the bound is exact" do
      Application.put_env(:samen_core, :audit_future_skew_seconds, 3_600)
      on_exit(fn -> Application.delete_env(:samen_core, :audit_future_skew_seconds) end)
      inside = DateTime.add(DateTime.utc_now(), 3_000) |> DateTime.truncate(:microsecond)
      outside = DateTime.add(DateTime.utc_now(), 4_000) |> DateTime.truncate(:microsecond)

      assert {:ok, %{aud_event: kept}} = write(%{occurred_at: inside})
      assert kept.occurred_at == inside

      capture_log(fn -> assert {:ok, %{aud_event: clamped}} = write(%{occurred_at: outside}) ; send(self(), {:c, clamped}) end)
      assert_received {:c, clamped}
      assert DateTime.compare(clamped.occurred_at, outside) == :lt
    end

    test "a future time can never make an audited write fail, with or without a DEFAULT partition" do
      Repo.query!("DROP TABLE aud_event_default")
      future = DateTime.add(DateTime.utc_now(), 5 * 365 * 86_400)
      capture_log(fn -> assert {:ok, %{aud_event: aud}} = write(%{occurred_at: future}) ; send(self(), {:a, aud}) end)
      assert_received {:a, aud}
      assert DateTime.diff(DateTime.utc_now(), aud.occurred_at, :second) in 0..5
    end
  end
end
