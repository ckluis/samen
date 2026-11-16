defmodule Samen.SingleNode.Peers do
  @redisconnect_ms 10
  @stuck_report_every 100

  @moduledoc """
  The runtime half of the distributed-Erlang guard (`Samen.SingleNode`, ADR-054).

  Subscribes to `:net_kernel` node events of BOTH kinds (`node_type: :all`) and decides per event:

    * `:hidden` — ALLOWED. `bin/app remote`, `bin/app rpc` and `iex --hidden --remsh` start hidden nodes (Mix
      releases pass `--hidden`), and so should `:observer`. They never enter `Node.list/0` and cannot share
      state with this node; refusing them would remove the operator's only way into a wedged production node.
    * `:visible` (or an event that does not say) — REFUSED, fail closed: reported loudly (`Logger.error`, a
      value-free `Samen.Observability.Failure` report, `[:samen, :single_node, :peer, :refused]`) and the peer is
      DISCONNECTED.

  ### Why disconnect and not stop the node

  Stopping would let anyone holding the release cookie take the service down with one connect call, and gains
  nothing: no Samen code uses distribution, so the invariant ("no node-local state is read by another node") holds
  the moment the peer is gone. A peer that reconnects is refused and reported again — every time, so a persistent
  clusterer is a rising series, not a quiet success.

  ### No race

  The subscription is made BEFORE `Node.list/0` is scanned in `init/1`, so a node that connects between the two
  is seen by one, the other, or both (handled idempotently) — never by neither.

  ### A disconnect that did nothing is repeated until the peer is gone

  `Node.disconnect/1` returns `false` for a node `:net_kernel` does not hold as up. That is also true for a
  short window right AFTER the node-up event: the runtime announces the connection (`erlang:setnode`) before
  the connection's setup process has told `:net_kernel` about it, so a guard that reacts at once finds the
  connection still "pending" there, the call is a no-op, and the peer STAYS CONNECTED (measured on OTP 29
  under CPU load: about 1 connect in 300). So an outcome other than `true` is never taken as "gone": while the
  node is still in `Node.list(:connected)` the disconnect is repeated every `#{@redisconnect_ms}` ms, and a
  peer that survives `#{@stuck_report_every}` attempts is reported again (`:peer_still_connected`) — each time.
  The loop ends only when the runtime no longer lists the node.
  """
  use GenServer

  require Logger

  alias Samen.Observability.Failure

  @doc "Pure decision for one node event's info list: `:allow | :refuse`. Anything but `:hidden` is refused."
  @spec decide(term()) :: :allow | :refuse
  def decide(info) when is_list(info) do
    case Keyword.get(info, :node_type) do
      :hidden -> :allow
      _ -> :refuse
    end
  end

  def decide(_), do: :refuse

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    disconnect = Keyword.get(opts, :disconnect, &Node.disconnect/1)
    :ok = :net_kernel.monitor_nodes(true, [{:node_type, :all}])
    state = %{
      disconnect: disconnect,
      connected?: Keyword.get(opts, :connected?, &connected?/1),
      redisconnect_ms: Keyword.get(opts, :redisconnect_ms, @redisconnect_ms)
    }

    # Subscribed first, scanned second (see "No race"). `Node.list/0` is the visible set by definition.
    for node <- Node.list(), do: refuse(node, state)
    {:ok, state}
  end

  @impl true
  def handle_info({:nodeup, node, info}, state) do
    case decide(info) do
      :allow ->
        :telemetry.execute([:samen, :single_node, :peer, :allowed], %{count: 1}, %{})
        Logger.info("[Samen.SingleNode] hidden node connected (operator console / rpc) node=#{node}")

      :refuse ->
        refuse(node, state)
    end

    {:noreply, state}
  end

  def handle_info({:redisconnect, node, attempt}, state) do
    if state.connected?.(node) do
      outcome = state.disconnect.(node)

      cond do
        outcome == true ->
          Logger.warning("[Samen.SingleNode] visible peer node disconnected on attempt #{attempt} node=#{node}")

        rem(attempt, @stuck_report_every) == 0 ->
          Logger.error(
            "[Samen.SingleNode] visible peer node STILL CONNECTED after #{attempt} disconnect attempts node=#{node} " <>
              "last=#{inspect(outcome)} (#{Samen.SingleNode.adr()})"
          )

          Failure.report(:write, :single_node_peer, nil, :peer_still_connected, [])

        true ->
          :ok
      end

      until_gone(node, outcome, attempt + 1, state)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp connected?(node), do: node in Node.list(:connected)

  # `true` is the only outcome that means the connection was taken down (see the moduledoc). Anything else is
  # checked against the runtime's own list and repeated while the node is still there.
  defp until_gone(_node, true, _attempt, _state), do: :ok

  defp until_gone(node, _outcome, attempt, state) do
    if state.connected?.(node), do: Process.send_after(self(), {:redisconnect, node, attempt}, state.redisconnect_ms)
    :ok
  end

  defp refuse(node, %{disconnect: disconnect} = state) do
    outcome = disconnect.(node)

    Logger.error(
      "[Samen.SingleNode] visible peer node refused node=#{node} disconnected=#{inspect(outcome)} — " <>
        "Samen runs as ONE instance per database (#{Samen.SingleNode.adr()}); remove the clustering configuration"
    )

    Failure.report(:write, :single_node_peer, nil, :visible_peer, [])
    :telemetry.execute([:samen, :single_node, :peer, :refused], %{count: 1}, %{})
    until_gone(node, outcome, 2, state)
  end
end
