defmodule Samen.SingleNode.Peers do
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
    state = %{disconnect: disconnect}
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

  def handle_info(_other, state), do: {:noreply, state}

  defp refuse(node, %{disconnect: disconnect}) do
    outcome = disconnect.(node)

    Logger.error(
      "[Samen.SingleNode] visible peer node refused node=#{node} disconnected=#{inspect(outcome)} — " <>
        "Samen runs as ONE instance per database (#{Samen.SingleNode.adr()}); remove the clustering configuration"
    )

    Failure.report(:write, :single_node_peer, nil, :visible_peer, [])
    :telemetry.execute([:samen, :single_node, :peer, :refused], %{count: 1}, %{})
    :ok
  end
end
