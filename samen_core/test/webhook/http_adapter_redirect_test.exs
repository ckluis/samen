defmodule Samen.Webhook.HttpAdapterRedirectTest do
  @moduledoc """
  Issue #25 step 4 — the SHARED `Samen.Webhook.HttpAdapter.Httpc` must NOT follow
  redirects.

  `:httpc`'s default is to follow. The adapter is reached with a tenant-supplied URL, so
  following let an apparently-public endpoint 302-pivot to loopback or
  `169.254.169.254` AFTER `Samen.Egress.Guard` had cleared the original host — the
  redirect defeats the check rather than being caught by it.

  This is a MECHANISM test, not a stub assertion: two real `:gen_tcp` listeners on
  127.0.0.1. The first answers `302` with a `Location:` pointing at the second. The
  adapter must return `{:error, {:http_status, 302}}` and the second listener must never
  see a connection. With `:autoredirect` back on, httpc dials the second listener and
  both halves of that assertion flip.

  No external network: both sockets are loopback, ephemeral ports.
  """
  use ExUnit.Case, async: false

  alias Samen.Webhook.HttpAdapter.Httpc

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    :ok
  end

  test "#25 RED: the shared adapter does not follow a 302 — the pivot target is never dialed" do
    test_pid = self()

    # The PIVOT listener: anything that reaches it is a followed redirect.
    {:ok, pivot} = listen()
    {:ok, pivot_port} = :inet.port(pivot)

    spawn_link(fn ->
      case :gen_tcp.accept(pivot, 3_000) do
        {:ok, socket} ->
          send(test_pid, :pivot_was_dialed)
          :gen_tcp.close(socket)

        {:error, :timeout} ->
          send(test_pid, :pivot_never_dialed)

        {:error, _other} ->
          :ok
      end
    end)

    # The ORIGIN listener: answers one 302 toward the pivot, then closes.
    {:ok, origin} = listen()
    {:ok, origin_port} = :inet.port(origin)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(origin, 3_000)
      _request = :gen_tcp.recv(socket, 0, 3_000)

      :gen_tcp.send(socket, [
        "HTTP/1.1 302 Found\r\n",
        "Location: http://127.0.0.1:#{pivot_port}/pivoted\r\n",
        "Content-Length: 0\r\n",
        "Connection: close\r\n\r\n"
      ])

      :gen_tcp.close(socket)
    end)

    result =
      Httpc.post(
        "http://127.0.0.1:#{origin_port}/hook",
        ~s({"event":"invoice.created"}),
        [{"Content-Type", "application/json"}, {"Samen-Signature", "t=1,v1=deadbeef"}]
      )

    assert result == {:error, {:http_status, 302}},
           "a 3xx must surface as a delivery failure, not be followed (got #{inspect(result)})"

    assert_receive :pivot_never_dialed, 5_000
    refute_received :pivot_was_dialed

    :gen_tcp.close(origin)
    :gen_tcp.close(pivot)
  end

  test "#25 POSITIVE CONTROL: the shared adapter still delivers to a 200 responder" do
    {:ok, origin} = listen()
    {:ok, origin_port} = :inet.port(origin)
    test_pid = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(origin, 3_000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 3_000)
      send(test_pid, {:request, IO.iodata_to_binary(request)})

      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\n",
        "Content-Length: 2\r\n",
        "Connection: close\r\n\r\n",
        "ok"
      ])

      :gen_tcp.close(socket)
    end)

    assert {:ok, 200} =
             Httpc.post("http://127.0.0.1:#{origin_port}/hook", ~s({"a":1}), [
               {"Samen-Signature", "t=1,v1=deadbeef"}
             ])

    assert_receive {:request, request}, 5_000
    assert request =~ "POST /hook"
    assert request =~ "samen-signature: t=1,v1=deadbeef" or request =~ "Samen-Signature: t=1,v1=deadbeef"

    :gen_tcp.close(origin)
  end

  defp listen do
    :gen_tcp.listen(0, [:binary, {:packet, :raw}, {:active, false}, {:reuseaddr, true}, {:ip, {127, 0, 0, 1}}])
  end
end
