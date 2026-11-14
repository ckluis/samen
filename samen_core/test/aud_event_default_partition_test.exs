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
    6. `occurred_at` at the Writer chokepoint: a future time is clamped, a past one kept, nothing rejected.
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
        AuditEvent.insert(Repo, %{event_type: "system", subject_id: "a", occurred_at: ~U[2099-05-05 05:00:00Z]})
      end
    end

    test "WITH the DEFAULT partition the same insert succeeds and sits in it; an in-window row does not" do
      subject = "default-#{System.unique_integer([:positive])}"
      row = insert!(subject, ~U[2099-05-05 05:00:00Z])
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

      log = capture_log(fn -> insert!(subject, ~U[2099-06-06 06:00:00Z]) end)

      assert log =~ "audit_event_in_default_partition"
      refute log =~ subject
      refute log =~ "2099"
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
      insert!("refuse-#{System.unique_integer([:positive])}", ~U[2097-03-10 00:00:00Z])
      name = PartitionManager.partition_name(~D[2097-03-01])
      {_, from_ts, to_ts} = PartitionManager.partition_spec(~D[2097-03-01])

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
      march_row = insert!(march, ~U[2097-03-10 10:00:00Z])
      insert!(march2, ~U[2097-03-31 23:59:59Z])
      insert!(may, ~U[2097-05-10 10:00:00Z])
      assert in_default(march) == 1

      %{rows: [[total_before]]} = Repo.query!("SELECT count(*) FROM aud_event")
      name = PartitionManager.partition_name(~D[2097-03-01])

      capture_log(fn -> assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[2097-03-01]) end)

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
      may_name = PartitionManager.partition_name(~D[2097-05-01])
      capture_log(fn -> assert {:ok, ^may_name} = PartitionManager.ensure_partition(Repo, ~D[2097-05-01]) end)
      assert in_partition(may_name, may) == 1
      assert in_default(may) == 0

      # idempotent, and the DEFAULT partition is still attached and still catches
      assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[2097-03-01])
      late = "late-#{tag}"
      insert!(late, ~U[2097-08-08 00:00:00Z])
      assert in_default(late) == 1
    end

    test "positive control: with nothing in DEFAULT for the month it is a plain create, other rows untouched" do
      tag = System.unique_integer([:positive])
      other = "other-#{tag}"
      insert!(other, ~U[2097-09-09 09:00:00Z])
      name = PartitionManager.partition_name(~D[2097-07-01])

      log = capture_log(fn -> assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[2097-07-01]) end)

      refute log =~ "moved rows"
      assert in_default(other) == 1
    end

    test "a database without a DEFAULT partition (not yet migrated) still rolls forward" do
      Repo.query!("DROP TABLE aud_event_default")
      name = PartitionManager.partition_name(~D[2097-11-01])
      assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[2097-11-01])
    end

    @tag :commit
    test "the move also works with a real COMMIT (auto mode), and loses no row" do
      Samen.TestSandbox.auto!(Repo)
      tag = System.unique_integer([:positive])
      subject = "commit-#{tag}"
      name = PartitionManager.partition_name(~D[2096-04-01])

      on_exit(fn ->
        Repo.query("DROP TABLE IF EXISTS #{name}")
        # the committed DEFAULT row goes with a TRUNCATE (the append-only trigger is row-level)
        Repo.query("TRUNCATE aud_event_default")
      end)

      insert!(subject, ~U[2096-04-04 04:00:00Z])
      assert in_default(subject) == 1

      capture_log(fn -> assert {:ok, ^name} = PartitionManager.ensure_partition(Repo, ~D[2096-04-01]) end)

      # a SECOND connection sees only committed data: the row is in the new partition, committed
      {from_other_connection, default_other} =
        Task.async(fn ->
          {in_partition(name, subject), in_default(subject)}
        end)
        |> Task.await()

      assert from_other_connection == 1 and default_other == 0
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
      insert!("runway-default-#{System.unique_integer([:positive])}", ~U[2099-01-01 00:00:00Z])

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
