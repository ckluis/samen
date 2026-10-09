defmodule Samen.Web.RequestIdProvenanceTest do
  @moduledoc """
  ADR-052 §2.1.2 item 1 — against the REAL `Plug.RequestId`: the request wide event carries the
  id only when the plug GENERATED it (and then it equals the `x-request-id` response header, so
  the event stays correlatable); a client-sent `x-request-id` — which the plug adopts verbatim
  for any 20–200-byte value — reaches the event only as a bounded `sub_` substitute.
  """
  use ExUnit.Case, async: false

  alias Samen.Observability.LiveTelemetry

  @collector {__MODULE__, :collector}

  def collect(_event, measurements, metadata, test_pid),
    do: send(test_pid, {:wide_event, Map.merge(metadata, measurements)})

  setup do
    LiveTelemetry.detach()
    :ok = LiveTelemetry.attach()

    :ok =
      :telemetry.attach(
        @collector,
        Samen.WideEvent.telemetry_event(),
        &__MODULE__.collect/4,
        self()
      )

    on_exit(fn ->
      LiveTelemetry.detach()
      :telemetry.detach(@collector)
    end)

    Logger.metadata(request_id: nil)
    :ok
  end

  # Plug.RequestId sets the Logger metadata + response header; the endpoint stop event then
  # fires in the same process, as Plug.Telemetry emits it.
  defp request(req_headers) do
    conn =
      Enum.reduce(req_headers, Plug.Test.conn(:get, "/contacts"), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)
      |> Plug.RequestId.call(Plug.RequestId.init([]))
      |> Plug.Conn.put_status(200)

    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1_000}, %{
      conn: conn,
      options: [log: false]
    })

    assert_receive {:wide_event, ev}, 1000
    [header] = Plug.Conn.get_resp_header(conn, "x-request-id")
    {ev, header}
  after
    Logger.metadata(request_id: nil)
  end

  test "POSITIVE CONTROL: a plug-generated id IS the event's request_id (== response header)" do
    {ev, header} = request([])
    assert ev.request_id == header
    assert byte_size(header) == 20
  end

  test "a client x-request-id is adopted by the plug, but never reaches the event" do
    client = "alice@example.com-support-4711"
    {ev, header} = request([{"x-request-id", client}])

    # The plug really did adopt it (the leak path this guards) …
    assert header == client
    # … and the sink sees only a bounded substitute.
    assert ev.request_id =~ ~r/\Asub_[A-Za-z0-9_-]{16}\z/
    refute inspect(ev) =~ "alice"
  end
end
