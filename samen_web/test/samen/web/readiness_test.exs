defmodule Samen.Web.ReadinessTest do
  @moduledoc """
  Red-path proofs for `Samen.Web.Readiness` (WS-F1 / F1.2) — the readiness probe
  behind the generated app's `GET /readyz`, which Fly's traffic gate rides.

  The contract under test: `check/1` returns `{:ok, checks}` ONLY when all three
  dependencies answer, and `{:error, checks}` — a 503, never a false 200 — the moment
  ANY of Postgres / the KMS wrapped-DEK store / Oban is unreachable. Each red path is
  paired with a POSITIVE CONTROL (the other two components stay `:ok`), so a blanket
  fail cannot masquerade as a discriminating one (anti-tautology).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Readiness

  # A KMS adapter whose wrapped-DEK store is UNREACHABLE — the fail-closed control.
  defmodule DownKms do
    @moduledoc false
    def attest(_subject), do: {:error, :unavailable}
  end

  setup do
    # Green KMS control: the in-memory adapter auto-starts and answers a read-only attest.
    prev_kms = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.InMemory)

    on_exit(fn ->
      if prev_kms do
        Application.put_env(:samen_core, :kms_adapter, prev_kms)
      else
        Application.delete_env(:samen_core, :kms_adapter)
      end
    end)

    # Green Oban control: a running instance sharing the sandbox repo (no queues/plugins).
    _pid =
      start_supervised!(
        {Oban, repo: Repo, testing: :manual, plugins: false, name: __MODULE__.Oban}
      )

    # the partition advisory is cached per repo (60 s); a test must not read another test's answer
    Readiness.reset_advisory_cache(Repo)
    on_exit(fn -> Readiness.reset_advisory_cache(Repo) end)

    %{oban: __MODULE__.Oban}
  end

  describe "green: every dependency answers" do
    test "check/1 returns {:ok, ...} with all three components :ok", %{oban: oban} do
      assert {:ok, checks} = Readiness.check(repo: Repo, oban: oban)
      assert checks[:repo] == :ok
      assert checks[:kms] == :ok
      assert checks[:oban] == :ok
    end
  end

  describe "red: Postgres unreachable" do
    test "repo down flips {:ok}→{:error}; kms + oban stay :ok (positive control)", %{oban: oban} do
      # A never-started repo — `Ecto.Adapters.SQL.query/3` raises on lookup; check fails closed.
      assert {:error, checks} = Readiness.check(repo: Samen.Web.ReadinessTest.PhantomRepo, oban: oban)
      assert match?({:error, _}, checks[:repo])
      # Anti-tautology: the OTHER probes still passed — the failure is discriminating.
      assert checks[:kms] == :ok
      assert checks[:oban] == :ok
    end
  end

  describe "red: KMS wrapped-DEK store unreachable" do
    test "kms :unavailable flips {:ok}→{:error}; repo + oban stay :ok (positive control)", %{oban: oban} do
      Application.put_env(:samen_core, :kms_adapter, DownKms)

      assert {:error, checks} = Readiness.check(repo: Repo, oban: oban)
      assert match?({:error, _}, checks[:kms])
      assert checks[:repo] == :ok
      assert checks[:oban] == :ok
    end
  end

  describe "red: Oban not running" do
    test "oban down flips {:ok}→{:error}; repo + kms stay :ok (positive control)" do
      # An Oban instance that was never started — `Oban.config/1` raises; check fails closed.
      assert {:error, checks} = Readiness.check(repo: Repo, oban: :samen_readiness_no_such_oban)
      assert match?({:error, _}, checks[:oban])
      assert checks[:repo] == :ok
      assert checks[:kms] == :ok
    end
  end

  # A repo whose catalog cannot be read.
  defmodule BlindRepo do
    def query(_sql, _params \\ []), do: {:error, %DBConnection.ConnectionError{message: "down"}}
    # the probe reads inside a transaction (to carry `lock_timeout`): an unreachable database fails it the same way
    def transaction(_fun, _opts \\ []), do: {:error, %DBConnection.ConnectionError{message: "down"}}
  end

  describe "single_node (ADR-054): a second instance on this database" do
    # The lease publishes its status in this table; the tests publish the same shapes the lease does.
    @table Samen.SingleNode.Lease.default_table()

    defp publish(raw) do
      :ets.new(@table, [:named_table, :public])
      # the lease stamps every state with when it was published and how long that stays believable
      :ets.insert(@table, {:status, Map.merge(%{at: System.monotonic_time(:millisecond), stale_ms: 3_600_000}, raw)})
    end

    defp overlap(opts) do
      Map.merge(
        %{state: :overlap, peers: 1, since: System.monotonic_time(:millisecond), late?: true, verified?: true, grace_ms: 300_000, strict: false},
        Map.new(opts)
      )
    end

    test "no lease on this node: no single_node line at all (existing bodies unchanged)", %{oban: oban} do
      refute Keyword.has_key?(Readiness.advisories(repo: Repo), :single_node)
      assert {200, "ready"} = Readiness.report(repo: Repo, oban: oban)
    end

    test "alone: ok, body is just `ready`", %{oban: oban} do
      publish(%{state: :single, strict: false})
      assert Readiness.advisories(repo: Repo)[:single_node] == :ok
      assert {200, "ready"} = Readiness.report(repo: Repo, oban: oban)
    end

    test "overlap inside the grace period is not an advisory (a rolling deploy)", %{oban: oban} do
      publish(overlap(since: System.monotonic_time(:millisecond)))
      assert Readiness.advisories(repo: Repo)[:single_node] == :ok
      assert {200, "ready"} = Readiness.report(repo: Repo, oban: oban)
    end

    test "overlap past the grace period: `single_node: CRITICAL` in a 200 body (strict off)", %{oban: oban} do
      publish(overlap(since: System.monotonic_time(:millisecond) - 301_000))
      assert {:critical, detail} = Readiness.advisories(repo: Repo)[:single_node]
      assert detail =~ "ADR-054"

      assert {200, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "ready\nsingle_node: CRITICAL 1 other instance(s)"
    end

    test "unreadable lease is `single_node: UNKNOWN`, never ok and never absent", %{oban: oban} do
      publish(%{state: :unknown, reason: :connection_pooler, strict: false})
      assert {:unknown, _} = Readiness.advisories(repo: Repo)[:single_node]
      assert {200, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "single_node: UNKNOWN single-node state unreadable (connection_pooler)"
    end

    test "strict: the LATE instance past grace is a 503; the early one and a within-grace late one stay ready", %{oban: oban} do
      stale = System.monotonic_time(:millisecond) - 301_000

      publish(overlap(since: stale, strict: true, late?: true))
      assert {503, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "not ready"
      assert body =~ "single_node: FAIL"
      assert body =~ "single_node: CRITICAL"
      assert {:error, checks} = Readiness.check(repo: Repo, oban: oban)
      assert checks[:repo] == :ok and checks[:kms] == :ok and checks[:oban] == :ok
      assert checks[:single_node] == {:error, :overlap}
      :ets.delete(@table)

      publish(overlap(since: stale, strict: true, late?: false))
      assert {200, _} = Readiness.report(repo: Repo, oban: oban)
      :ets.delete(@table)

      publish(overlap(since: System.monotonic_time(:millisecond), strict: true, late?: true))
      assert {200, "ready"} = Readiness.report(repo: Repo, oban: oban)
    end

    test "a lease that died (armed node, no table) is UNKNOWN in a 200 body, also with strict on", %{oban: oban} do
      Samen.SingleNode.arm(@table)
      on_exit(fn -> Samen.SingleNode.disarm(@table) end)

      assert {:unknown, detail} = Readiness.advisories(repo: Repo)[:single_node]
      assert detail =~ "lease_not_running"
      assert {200, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "single_node: UNKNOWN"
      refute body =~ "single_node: FAIL"

      Application.put_env(:samen_core, Samen.SingleNode, strict: true)
      on_exit(fn -> Application.delete_env(:samen_core, Samen.SingleNode) end)
      # strict never turns "cannot tell" into a 503
      assert {200, _} = Readiness.report(repo: Repo, oban: oban)
    end

    test "a hung lease's last word expires: a published `single` older than its stale_ms is UNKNOWN", %{oban: oban} do
      publish(%{state: :single, strict: false, at: System.monotonic_time(:millisecond) - 10_000, stale_ms: 5_000})
      assert {:unknown, detail} = Readiness.advisories(repo: Repo)[:single_node]
      assert detail =~ "lease_stale"
      assert {200, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "single_node: UNKNOWN"
    end

    setup do
      on_exit(fn -> if :ets.whereis(@table) != :undefined, do: :ets.delete(@table) end)
    end
  end

  describe "advisories: the audit-partition runway (ARCH-9) never takes the node out of rotation" do
    test "healthy: :ok, and the body is exactly `ready`", %{oban: oban} do
      Repo.query!("TRUNCATE aud_event_default")
      assert [partitions: :ok] = Readiness.advisories(repo: Repo)
      assert {200, "ready"} = Readiness.report(repo: Repo, oban: oban)
    end

    test "rows in DEFAULT: a WARNING line in a 200 body (not a 503); positive control above", %{oban: oban} do
      Repo.query!("TRUNCATE aud_event_default")
      {:ok, _} = Samen.AuditEvent.insert(Repo, %{event_type: "system", occurred_at: ~U[1999-01-01 00:00:00Z]})

      assert [partitions: {:warn, detail}] = Readiness.advisories(repo: Repo)
      assert detail =~ "default_rows=1"

      assert {200, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "ready\npartitions: WARN aud_event: runway_days="
    end

    test "no partition covers now: CRITICAL, still a 200", %{oban: oban} do
      # every partition dropped but the DEFAULT: runway is behind us
      %{rows: rows} =
        Repo.query!(
          "SELECT c.relname FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhparent " <>
            "JOIN pg_class c ON c.oid = i.inhrelid WHERE p.relname = 'aud_event' AND c.relname <> 'aud_event_default'"
        )

      for [name] <- rows, do: Repo.query!("DROP TABLE #{name}")

      assert [partitions: {:critical, detail}] = Readiness.advisories(repo: Repo)
      assert detail =~ "runway_critical"
      assert {200, body} = Readiness.report(repo: Repo, oban: oban)
      assert body =~ "partitions: CRITICAL"
    end

    test "unreadable runway is UNKNOWN, never :ok (and an unreachable catalog does not crash the probe)" do
      assert [partitions: {:unknown, detail}] = Readiness.advisories(repo: BlindRepo)
      assert detail =~ "DBConnection.ConnectionError"
      refute detail =~ "down"

      assert [partitions: {:unknown, _}] = Readiness.advisories(repo: Samen.Web.ReadinessTest.PhantomRepo)
    end

    test "a dependency failure is still a 503, advisory lines appended", %{oban: _oban} do
      assert {503, body} = Readiness.report(repo: Repo, oban: :samen_readiness_no_such_oban)
      assert body =~ "not ready\n"
      assert body =~ "oban: FAIL"
    end
  end
  # A repo whose catalog read never returns: a probe stuck behind a lock the database never grants.
  defmodule HangRepo do
    def query(_sql, _params \\ []), do: hang()
    def transaction(_fun, _opts \\ []), do: hang()

    defp hang do
      receive do
        :never -> :never
      end
    end
  end

  describe "advisories: the probe never blocks /readyz, and the cache is fail-honest" do
    @key {Samen.Web.Readiness, :partitions, Samen.Web.ReadinessTest.BlindRepo}

    setup do
      on_exit(fn -> :persistent_term.erase(@key) end)
      :ok
    end

    test "a read that never returns is UNKNOWN within the deadline (not a hung probe) and emits runway_unknown" do
      me = self()
      id = {__MODULE__, make_ref()}
      :telemetry.attach(id, [:samen, :audit, :partition, :runway_unknown], fn _, meas, _, _ -> send(me, {:unknown_signal, meas}) end, nil)
      on_exit(fn -> :telemetry.detach(id) end)

      started = System.monotonic_time(:millisecond)
      assert [partitions: {:unknown, detail}] = Readiness.advisories(repo: HangRepo)
      assert detail =~ "deadline_exceeded"
      # the metrics side says it too (the alert pages on `runway_unknown`, not on the probe body)
      assert_received {:unknown_signal, %{count: 1}}
      assert System.monotonic_time(:millisecond) - started < 1_500
      # UNKNOWN is not cached: positive control that nothing was stored
      assert :persistent_term.get({Samen.Web.Readiness, :partitions, HangRepo}, nil) == nil
    end

    test "within the TTL the cached advisory answers without touching the database" do
      :persistent_term.put(@key, {System.monotonic_time(:millisecond), :ok})
      # BlindRepo cannot be queried at all: only the cache can say :ok
      assert [partitions: :ok] = Readiness.advisories(repo: BlindRepo)
    end

    test "past the TTL a failed refresh is UNKNOWN, never the old :ok" do
      :persistent_term.put(@key, {System.monotonic_time(:millisecond) - 61_000, :ok})
      assert [partitions: {:unknown, _}] = Readiness.advisories(repo: BlindRepo)
    end

    test "a successful read is cached: a change in the database shows only after the TTL / a reset" do
      Repo.query!("TRUNCATE aud_event_default")
      assert [partitions: :ok] = Readiness.advisories(repo: Repo)
      {:ok, _} = Samen.AuditEvent.insert(Repo, %{event_type: "system", occurred_at: ~U[1999-01-01 00:00:00Z]})
      assert [partitions: :ok] = Readiness.advisories(repo: Repo)
      Readiness.reset_advisory_cache(Repo)
      assert [partitions: {:warn, _}] = Readiness.advisories(repo: Repo)
    end

    test "no partitioned table at all is UNKNOWN, not ok" do
      Repo.query!("DROP TABLE aud_event CASCADE")
      assert [partitions: {:unknown, detail}] = Readiness.advisories(repo: Repo)
      assert detail =~ "no_partitioned_table"
    end

    test "a table whose bounds cannot be read is UNKNOWN and the detail names it" do
      Repo.query!("CREATE TABLE tmp_time_range (at timestamptz NOT NULL) PARTITION BY RANGE (at)")
      Repo.query!("CREATE TABLE tmp_time_range_p PARTITION OF tmp_time_range FOR VALUES FROM (MINVALUE) TO (MAXVALUE)")

      assert [partitions: {:unknown, detail}] = Readiness.advisories(repo: Repo)
      assert detail =~ "tmp_time_range"
    end
  end
end
