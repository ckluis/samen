defmodule Samen.SingleNodeTest do
  @moduledoc """
  ADR-054 — the single-node guard, distributed-Erlang half, arming and the readiness advisory.

  Proven (each with a positive control, so no assertion can pass vacuously):

    1. the peer DECISION: hidden is allowed, visible and "does not say" are refused;
    2. the REAL thing: a genuine `:peer` node that connects visible is refused and disconnected, one that
       connects hidden (how `bin/app remote` / `rpc` start) is left alone and still connected;
    3. the BOOT guard: a connected visible node or a configured clustering library fails boot, naming the ADR;
    4. ARMING: `child_specs/2` is empty unless the instance is serving (`mix test`, mix tasks, migrations and
       release `eval` are not), and the lease takes no lock when it is not armed;
    5. the ADVISORY and strict check as a function of the published status (grace boundary exact).
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Samen.SingleNode
  alias Samen.SingleNode.Peers

  describe "Peers.decide/1" do
    test "hidden is allowed; visible, missing and malformed info are refused (fail closed)" do
      assert Peers.decide(node_type: :hidden) == :allow
      assert Peers.decide(node_type: :visible) == :refuse
      assert Peers.decide([]) == :refuse
      assert Peers.decide(:garbage) == :refuse
    end
  end

  # `:peer` and `:net_kernel.start/1` need an epmd. Find it on PATH, else inside the running OTP (`erts-*/bin`), and
  # FAIL with a named message when there is none: a skipped distribution test would leave the guard unproven.
  defp ensure_epmd! do
    found =
      System.find_executable("epmd") ||
        [to_string(:code.root_dir()), "erts-*", "bin", "epmd"] |> Path.join() |> Path.wildcard() |> List.first()

    case found do
      nil ->
        raise ExUnit.AssertionError,
          message:
            "epmd (the Erlang port mapper) was not found on PATH or under #{:code.root_dir()}/erts-*/bin; " <>
              "the distributed-Erlang tests need it (install Erlang/OTP with its bin directory, or put epmd on PATH)"

      path ->
        case System.cmd(path, ["-daemon"], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, code} -> raise ExUnit.AssertionError, message: "`#{path} -daemon` failed (#{code}): #{out}"
        end
    end
  end

  defp disconnect_probe(test, node) do
    send(test, {:disconnected, node})
    true
  end

  describe "Peers server (injected events)" do
    setup do
      test = self()
      name = :"peers_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Peers, name: name, disconnect: fn node -> disconnect_probe(test, node) end}
      )

      handler = "peers-#{name}"

      :telemetry.attach_many(
        handler,
        [[:samen, :single_node, :peer, :refused], [:samen, :single_node, :peer, :allowed], [:samen, :core, :write, :error]],
        fn event, _m, meta, _ -> send(test, {:telemetry, event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{name: name}
    end

    test "a visible peer is disconnected and reported, not silently accepted", %{name: name} do
      send(name, {:nodeup, :"intruder@host", [node_type: :visible]})

      assert_receive {:disconnected, :"intruder@host"}
      assert_receive {:telemetry, [:samen, :single_node, :peer, :refused], _}
      assert_receive {:telemetry, [:samen, :core, :write, :error], %{write: :single_node_peer, cause: "visible_peer"}}
    end

    test "a hidden node is accepted: not disconnected, no refusal (positive control for the test above)", %{name: name} do
      send(name, {:nodeup, :"rem-1@host", [node_type: :hidden]})

      assert_receive {:telemetry, [:samen, :single_node, :peer, :allowed], _}
      refute_received {:disconnected, _}
      refute_received {:telemetry, [:samen, :single_node, :peer, :refused], _}
    end
  end

  # Node up/down and the guard's verdict travel through net_kernel and a second OS process, so they arrive
  # when the distribution layer gets to them, not within ExUnit's default 100 ms (a loaded CI runner took
  # longer and the test flaked). Each receive below returns the moment its message arrives; this is only the
  # deadline after which a missing message is a failure.
  @dist_deadline 5_000

  describe "Peers with real distributed nodes" do
    setup do
      ensure_epmd!()

      started? =
        if Node.alive?() do
          false
        else
          {:ok, _} = :net_kernel.start([:"samen_sn_#{System.unique_integer([:positive])}@127.0.0.1", :longnames])
          true
        end

      :net_kernel.monitor_nodes(true, [{:node_type, :all}])
      test = self()
      handler = "peers-real-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:samen, :single_node, :peer, :refused], [:samen, :single_node, :peer, :allowed]],
        fn event, _m, _meta, _ -> send(test, {:telemetry, event}) end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach(handler)
        if started?, do: :net_kernel.stop()
      end)

      %{me: node()}
    end

    defp start_guard, do: start_supervised!({Peers, name: :"peers_real_#{System.unique_integer([:positive])}"})

    defp start_peer(args) do
      {:ok, peer, _node} =
        :peer.start_link(%{
          name: :"sn_peer_#{System.unique_integer([:positive])}",
          host: ~c"127.0.0.1",
          longnames: true,
          args: args,
          connection: 0
        })

      peer
    end

    test "a VISIBLE node that joins is refused and disconnected", %{me: me} do
      start_guard()
      peer = start_peer([])
      assert :peer.call(peer, :net_kernel, :connect_node, [me])

      assert_receive {:nodeup, peer_node, [node_type: :visible]}, @dist_deadline
      assert_receive {:telemetry, [:samen, :single_node, :peer, :refused]}, @dist_deadline
      assert_receive {:nodedown, ^peer_node, _}, @dist_deadline
      :peer.stop(peer)
    end

    test "a HIDDEN node (how `bin/app remote` starts) is accepted and stays connected", %{me: me} do
      start_guard()
      peer = start_peer([~c"-hidden"])
      assert :peer.call(peer, :net_kernel, :connect_node, [me])

      assert_receive {:nodeup, peer_node, [node_type: :hidden]}, @dist_deadline
      assert_receive {:telemetry, [:samen, :single_node, :peer, :allowed]}, @dist_deadline
      refute_received {:telemetry, [:samen, :single_node, :peer, :refused]}
      refute_received {:nodedown, ^peer_node, _}
      assert Node.list() == []
      :peer.stop(peer)
    end

    test "a visible node already connected when the guard starts is found by the scan (no subscribe/scan gap)", %{me: me} do
      peer = start_peer([])
      assert :peer.call(peer, :net_kernel, :connect_node, [me])
      assert_receive {:nodeup, peer_node, [node_type: :visible]}, @dist_deadline

      start_guard()

      assert_receive {:telemetry, [:samen, :single_node, :peer, :refused]}, @dist_deadline
      assert_receive {:nodedown, ^peer_node, _}, @dist_deadline
      :peer.stop(peer)
    end
  end

  describe "boot guard" do
    setup do
      saved = for {app, key} <- [{:libcluster, :topologies}, {:dns_cluster, :query}, {:samen_core, :dns_cluster_query}], do: {app, key, Application.get_env(app, key)}

      on_exit(fn ->
        for {app, key, val} <- saved do
          if is_nil(val), do: Application.delete_env(app, key), else: Application.put_env(app, key, val)
        end
      end)
    end

    test "standalone: no findings, no raise" do
      assert SingleNode.cluster_findings(:samen_core) == []
      assert SingleNode.assert_standalone!(:samen_core) == :ok
    end

    test "a configured libcluster topology fails boot and names the ADR" do
      Application.put_env(:libcluster, :topologies, local: [strategy: Cluster.Strategy.Epmd])
      assert SingleNode.cluster_findings(:samen_core) == ["libcluster topologies are configured"]

      e = assert_raise SingleNode.ClusteredError, fn -> SingleNode.assert_standalone!(:samen_core) end
      assert e.message =~ "ADR-054"
      assert e.message =~ "libcluster"
    end

    test "dns_cluster (its own app or the host's generated key) fails boot; :ignore does not" do
      Application.put_env(:dns_cluster, :query, "app.internal")
      assert [_] = SingleNode.cluster_findings(:samen_core)
      Application.put_env(:dns_cluster, :query, :ignore)
      assert SingleNode.cluster_findings(:samen_core) == []

      Application.put_env(:samen_core, :dns_cluster_query, "app.internal")
      assert ["samen_core :dns_cluster_query is configured"] = SingleNode.cluster_findings(:samen_core)
      assert_raise SingleNode.ClusteredError, fn -> SingleNode.assert_standalone!(:samen_core) end
    end

    test "a connected visible node fails boot" do
      ensure_epmd!()
      started? = not Node.alive?()
      if started?, do: {:ok, _} = :net_kernel.start([:"samen_sn_boot_#{System.unique_integer([:positive])}@127.0.0.1", :longnames])

      {:ok, peer, _} =
        :peer.start(%{name: :"sn_boot_#{System.unique_integer([:positive])}", host: ~c"127.0.0.1", longnames: true, connection: 0})

      on_exit(fn ->
        :peer.stop(peer)
        if started?, do: :net_kernel.stop()
      end)

      :net_kernel.monitor_nodes(true, [{:node_type, :all}])
      assert :peer.call(peer, :net_kernel, :connect_node, [node()])
      # the nodeup message orders the assertion after the connection is visible in Node.list/0
      assert_receive {:nodeup, _peer_node, [node_type: :visible]}, @dist_deadline
      assert [finding] = SingleNode.cluster_findings(:samen_core)
      assert finding =~ "visible nodes are connected"
      assert_raise SingleNode.ClusteredError, ~r/ADR-054/, fn -> SingleNode.assert_standalone!(:samen_core) end
    end
  end

  describe "arming (what `serving` means)" do
    setup do
      saved = Application.get_env(:phoenix, :serve_endpoints)
      Application.put_env(:samen_core, SnArmingFake.Endpoint, server: false)

      on_exit(fn ->
        # `child_specs` of a serving instance ARMS the default table; this VM runs no lease on it
        SingleNode.disarm()
        if is_nil(saved), do: Application.delete_env(:phoenix, :serve_endpoints), else: Application.put_env(:phoenix, :serve_endpoints, saved)
        Application.delete_env(:samen_core, SnArmingFake.Endpoint)
      end)
    end

    test "not serving (mix test / ecto.* / samen.* tasks / release eval): no children, nothing started" do
      refute SingleNode.serving?(:samen_core)
      assert SingleNode.child_specs(:samen_core) == []
    end

    test "serving via the endpoint's `server: true` (dev config, generated runtime.exs)" do
      Application.put_env(:samen_core, SnArmingFake.Endpoint, server: true)
      assert SingleNode.serving?(:samen_core)
      assert [{Peers, []}, {Samen.SingleNode.Lease, [repo: SamenCore.TestRepo]}] = SingleNode.child_specs(:samen_core, repo: SamenCore.TestRepo)
    end

    test "serving via `mix phx.server` (serve_endpoints) when the endpoint does not say otherwise" do
      Application.put_env(:samen_core, SnArmingFake.Endpoint, http: [port: 4000])
      Application.put_env(:phoenix, :serve_endpoints, true)
      assert SingleNode.serving?(:samen_core)
      Application.delete_env(:phoenix, :serve_endpoints)
      refute SingleNode.serving?(:samen_core)
    end

    test "an endpoint that says server: false wins over serve_endpoints — a seed task (Samen.SeedBoot) never arms" do
      Application.put_env(:samen_core, SnArmingFake.Endpoint, server: true, http: [port: 4000])
      Application.put_env(:phoenix, :serve_endpoints, true)
      assert SingleNode.serving?(:samen_core)

      # what `mix <app>.seed` does before `app.start`
      Samen.SeedBoot.disable_listener!(:samen_core, SnArmingFake.Endpoint)
      refute SingleNode.serving?(:samen_core)
      assert SingleNode.child_specs(:samen_core) == []
    end

    test "a serving instance with a clustering config fails to BUILD its children (boot refuses)" do
      Application.put_env(:libcluster, :topologies, local: [])
      on_exit(fn -> Application.delete_env(:libcluster, :topologies) end)

      assert_raise SingleNode.ClusteredError, fn -> SingleNode.child_specs(:samen_core, serving?: true) end
      # not serving: the same configuration is not this guard's business (a mix task in a clustered dev shell)
      assert SingleNode.child_specs(:samen_core, serving?: false) == []
    end

    test "no repo, no lease: only the peer monitor" do
      assert [{Peers, []}] = SingleNode.child_specs(:no_such_app_for_arming, serving?: true)
    end

    test "Observability.child_specs wires the guard for a serving host and omits it otherwise (zero host code)" do
      has_peers? = fn opts -> Enum.any?(Samen.Observability.child_specs(:samen_core, opts), &match?({Peers, _}, &1)) end

      Application.put_env(:samen_core, SnArmingFake.Endpoint, server: true)
      assert has_peers?.([])
      refute has_peers?.(single_node: false)

      Application.put_env(:samen_core, SnArmingFake.Endpoint, server: false)
      refute has_peers?.([])
    end
  end

  describe "status resolution, advisory and strict check" do
    # The lease publishes `at` (when) and `stale_ms` with every state; a state without them is stale by definition.
    defp ets(raw, fresh \\ %{at: 0, stale_ms: 1_000_000_000}) do
      table = :"sn_status_#{System.unique_integer([:positive])}"
      :ets.new(table, [:named_table, :public])
      :ets.insert(table, {:status, Map.merge(fresh, raw)})
      table
    end

    test "no lease on this node is :disarmed and advisory :ok; a lease that has not read yet is UNKNOWN, never single" do
      assert SingleNode.status(table: :no_such_table_sn) == :disarmed
      assert SingleNode.advisory(table: :no_such_table_sn) == :ok
      assert SingleNode.strict_check(table: :no_such_table_sn) == :not_armed

      table = :"sn_empty_#{System.unique_integer([:positive])}"
      :ets.new(table, [:named_table, :public])
      assert %{state: :unknown, reason: :starting} = SingleNode.status(table: table)
      assert {:unknown, detail} = SingleNode.advisory(table: table)
      assert detail =~ "starting"
    end

    test "single is ok; unknown carries its reason and is never ok" do
      assert SingleNode.advisory(table: ets(%{state: :single, strict: false})) == :ok

      assert {:unknown, detail} = SingleNode.advisory(table: ets(%{state: :unknown, reason: :connection_down, strict: false}))
      assert detail =~ "connection_down"
      assert detail =~ "ADR-054"
    end

    test "overlap: ok INSIDE the grace period, critical from the exact boundary on" do
      raw = %{state: :overlap, peers: 1, since: 1_000, late?: false, verified?: true, grace_ms: 300_000, strict: false}
      table = ets(raw)

      assert SingleNode.advisory(table: table, now: 1_000 + 299_999) == :ok
      assert {:critical, detail} = SingleNode.advisory(table: table, now: 1_000 + 300_000)
      assert detail =~ "1 other instance(s)"
      assert detail =~ "ADR-054"
      refute detail =~ "postgres"
    end

    test "strict: only the LATE instance, only past grace, only when strict" do
      base = %{state: :overlap, peers: 1, since: 0, grace_ms: 1_000, verified?: true}
      late = ets(Map.merge(base, %{late?: true, strict: true}))
      early = ets(Map.merge(base, %{late?: false, strict: true}))
      lax = ets(Map.merge(base, %{late?: true, strict: false}))
      unconfirmed = ets(Map.merge(base, %{late?: true, strict: true, verified?: false}))

      assert SingleNode.strict_check(table: late, now: 999) == :ok
      assert SingleNode.strict_check(table: late, now: 1_000) == {:error, :overlap}
      assert SingleNode.strict_check(table: early, now: 5_000) == :ok
      assert SingleNode.strict_check(table: lax, now: 5_000) == :not_armed
      # a holder not confirmed alive (its beat never changed: a ghost) is never a reason to refuse
      assert SingleNode.strict_check(table: unconfirmed, now: 5_000) == :ok
      assert {:unknown, _} = SingleNode.advisory(table: unconfirmed, now: 5_000)
    end

    test "strict never refuses on UNKNOWN, whatever the reason (a lone healthy instance must not 503 itself)" do
      for reason <- [:connection_down, :connection_pooler, :stale_holder, :lease_lost, :query_failed, :starting] do
        table = ets(%{state: :unknown, reason: reason, strict: true})
        assert %{state: :unknown, strict?: true} = SingleNode.status(table: table, now: 5_000)
        assert SingleNode.strict_check(table: table, now: 5_000) == :ok
        assert {:unknown, _} = SingleNode.advisory(table: table, now: 5_000)
      end

      # a stale published state, and an armed node whose lease is gone, are UNKNOWN too, with strict on
      stale = ets(%{state: :single, strict: true}, %{at: 0, stale_ms: 1_000})
      assert %{state: :unknown, reason: :lease_stale, strict?: true} = SingleNode.status(table: stale, now: 1_000)
      assert %{state: :single} = SingleNode.status(table: stale, now: 999)
      assert SingleNode.strict_check(table: stale, now: 1_000) == :ok

      # a state with no timestamp at all cannot be shown to be fresh
      untimed = ets(%{state: :single, strict: true}, %{})
      assert %{state: :unknown, reason: :lease_stale} = SingleNode.status(table: untimed, now: 0)
    end

    test "armed + no lease table is UNKNOWN :lease_not_running; never armed is :disarmed" do
      table = :"sn_armed_#{System.unique_integer([:positive])}"
      assert SingleNode.status(table: table) == :disarmed
      SingleNode.arm(table)
      on_exit(fn -> SingleNode.disarm(table) end)

      assert %{state: :unknown, reason: :lease_not_running} = SingleNode.status(table: table)
      assert {:unknown, detail} = SingleNode.advisory(table: table)
      assert detail =~ "lease_not_running"

      SingleNode.disarm(table)
      assert SingleNode.status(table: table) == :disarmed
    end
  end
end
