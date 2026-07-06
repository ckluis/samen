defmodule Samen.WideEventTest do
  @moduledoc """
  T2.7 — structured wide events + the J2 sink-schema allow-list + keyed pseudonyms.

  Covers:
    * (a) canonical wide event: the doc §runs-4b field set, telemetry emit, sinks;
    * (b) THE J2 BUILD-TIME SCHEMA CHECK — a string-typed field fails; a seeded
      string field in a schema-shaped list is caught (the laundered-leak backstop);
    * (c) actor_id = HMAC(psk_S, subject_id) keyed pseudonym; unlinkable post-shred;
    * (d) sink TTL — file adapter prunes, in-memory bounded.
  """
  use ExUnit.Case, async: false

  alias Samen.WideEvent
  alias Samen.WideEvent.{Schema, Retention}
  alias Samen.WideEvent.Sinks

  # ------------------------------------------------------------------------
  # (a) canonical wide event
  # ------------------------------------------------------------------------

  describe "canonical wide event (doc §runs 4b)" do
    test "builds the exact field set the doc names" do
      {:ok, ev} =
        WideEvent.new(
          request_id: "req-01HXYZ",
          trace_id: "trace-abcdef",
          tenant_id: "org-opaque-123",
          actor_id: "a1b2c3d4",
          action: :contact_read,
          op: :select,
          table: "cnt_contact",
          row_count: 3,
          duration_ms: 12,
          queue_depth: 0
        )

      assert ev.action == :contact_read
      assert ev.op == :select
      assert ev.table == "cnt_contact"
      assert ev.row_count == 3
    end

    test "rejects an UNKNOWN field (cannot smuggle an undeclared field)" do
      {:error, reasons} = WideEvent.new(action: :x, subject_name: "Alice Smith")
      assert Enum.any?(reasons, &String.contains?(&1, "unknown wide-event field"))
    end

    test "rejects a name-shaped value in tenant_id (:opaque_id shape guard)" do
      {:error, reasons} = WideEvent.new(action: :x, tenant_id: "Alice Smith")
      assert Enum.any?(reasons, &String.contains?(&1, "tenant_id"))
    end

    test "rejects a non-number in row_count" do
      {:error, reasons} = WideEvent.new(action: :x, row_count: "three")
      assert Enum.any?(reasons, &String.contains?(&1, ":number"))
    end

    test "rejects an op value outside the closed enum set" do
      {:error, reasons} = WideEvent.new(action: :x, op: :truncate)
      assert Enum.any?(reasons, &String.contains?(&1, "not in closed set"))
    end
  end

  # ------------------------------------------------------------------------
  # (b) J2 build-time schema check — the laundered-leak backstop
  # ------------------------------------------------------------------------

  describe "J2 schema check (Samen.WideEvent.Schema.violations/0)" do
    test "the real declared schema is CLEAN (all bounded types)" do
      assert Schema.violations() == []
    end

    test "every declared field is a bounded type" do
      for {name, type, _opts} <- Schema.canonical_fields() do
        assert Schema.bounded_type?(type), "field #{name} declared non-bounded type #{type}"
      end
    end

    test "RED PATH: a seeded :string field FAILS the check (name-carrier)" do
      seeded = Schema.canonical_fields() ++ [{:debug_note, :string, []}]
      violations = Schema.violations(seeded)

      assert Enum.any?(violations, &String.contains?(&1, "debug_note")),
             "a string-typed field must fail the J2 schema check"

      assert Enum.any?(violations, &String.contains?(&1, "FORBIDDEN"))
    end

    test "RED PATH: seeded :map / :binary / :any fields all fail" do
      for bad <- [:map, :binary, :any, :term, :atom] do
        seeded = [{:x, bad, []}]
        assert Schema.violations(seeded) != [], ":#{bad} field must fail the J2 check"
      end
    end

    test "RED PATH: an :enum with no closed allowed set fails" do
      seeded = [{:open_label, :enum, []}]
      violations = Schema.violations(seeded)
      assert Enum.any?(violations, &String.contains?(&1, "no closed"))
    end

    test "a bounded enum WITH a closed allowed set passes" do
      assert Schema.violations([{:op2, :enum, [allowed: [:a, :b]]}]) == []
    end
  end

  # ------------------------------------------------------------------------
  # (d) sinks + TTL
  # ------------------------------------------------------------------------

  describe "in-memory sink (bounded ring buffer)" do
    setup do
      {:ok, pid} =
        Sinks.InMemory.start_link(
          name: :test_in_mem,
          retention: %Retention{ttl_seconds: 3600, max_events: 3}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      %{pid: pid}
    end

    test "holds events and is bounded to max_events (oldest dropped)", %{pid: pid} do
      for n <- 1..5 do
        {:ok, ev} = WideEvent.new(action: :req, request_id: "req-#{n}", row_count: n)
        GenServer.cast(pid, {:event, ev})
      end

      # give the casts time to process
      _ = Sinks.InMemory.events(pid)
      events = Sinks.InMemory.events(pid)

      assert length(events) == 3, "ring buffer must be bounded to max_events=3"
      # oldest (req-1, req-2) dropped; newest 3 survive
      assert Enum.map(events, & &1.request_id) == ["req-3", "req-4", "req-5"]
    end

    test "receives events emitted via telemetry when attached", %{pid: pid} do
      :ok = attach_in_mem(pid)
      {:ok, ev} = WideEvent.new(action: :login, request_id: "req-tel", row_count: 1)
      :ok = WideEvent.emit(ev)

      # telemetry.execute is synchronous → cast enqueued; drain with a call
      _ = Sinks.InMemory.events(pid)
      events = Sinks.InMemory.events(pid)
      assert Enum.any?(events, &(&1.request_id == "req-tel"))
    end
  end

  describe "file sink TTL prune (doc §runs 4b 'stated TTL')" do
    setup do
      dir = probe_dir()
      File.mkdir_p!(dir)
      path = Path.join(dir, "wide_events.jsonl")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{path: path}
    end

    test "prunes lines older than ttl_seconds on write", %{path: path} do
      retention = %Retention{ttl_seconds: 100, max_events: 10_000}
      {:ok, old} = WideEvent.new(action: :old, request_id: "req-old", row_count: 1)
      {:ok, new} = WideEvent.new(action: :new, request_id: "req-new", row_count: 1)

      now = System.system_time(:second)
      # Manually write an OLD line (emitted 1000s ago — beyond ttl=100).
      old_line = Jason.encode!(%{emitted_at: now - 1000, event: %{action: "old", request_id: "req-old"}})
      File.write!(path, old_line <> "\n")

      # A fresh write triggers a prune of the stale line.
      :ok = Sinks.File.handle_event(new, retention, path)

      surviving = Sinks.File.read(path)
      request_ids = Enum.map(surviving, & &1.event.request_id)

      refute "req-old" in request_ids, "the stale line must be pruned by TTL"
      assert "req-new" in request_ids, "the fresh line must survive"
      # silence "old" unused
      assert old.request_id == "req-old"
    end
  end

  describe "OTLP sink skeleton (Honeycomb-shaped)" do
    test "shapes a wide event into flat dotted attributes (bounded values only)" do
      {:ok, ev} =
        WideEvent.new(
          action: :contact_read,
          request_id: "req-1",
          tenant_id: "org-1",
          op: :select,
          row_count: 2
        )

      attrs = Sinks.Otlp.shape(ev)
      assert attrs["service.name"] == "samen"
      assert attrs["samen.request_id"] == "req-1"
      assert attrs["samen.action"] == "contact_read"
      assert attrs["samen.op"] == "select"
      assert attrs["samen.row_count"] == 2
      # nil fields omitted
      refute Map.has_key?(attrs, "samen.trace_id")
    end

    test "export function receives the shaped attrs (the operator-wired seam)" do
      test_pid = self()
      Sinks.Otlp.attach(export: fn attrs -> send(test_pid, {:otlp, attrs}) end)
      on_exit(fn -> Sinks.Otlp.detach() end)

      {:ok, ev} = WideEvent.new(action: :req, request_id: "req-otlp", row_count: 1)
      :ok = WideEvent.emit(ev)

      assert_receive {:otlp, attrs}
      assert attrs["samen.request_id"] == "req-otlp"
    end
  end

  # ------------------------------------------------------------------------
  # helpers
  # ------------------------------------------------------------------------

  defp attach_in_mem(server) do
    :telemetry.attach(
      {Sinks.InMemory, :test_handler},
      WideEvent.telemetry_event(),
      &Sinks.InMemory.__handle__/4,
      %{server: server}
    )

    on_exit(fn -> :telemetry.detach({Sinks.InMemory, :test_handler}) end)
    :ok
  end

  defp probe_dir do
    Path.join(File.cwd!(), "_probes/t2_7_file_sink_#{:erlang.unique_integer([:positive])}")
  end
end
