defmodule Samen.Fleet.LocalCredentialAgentTest do
  @moduledoc """
  The reference `Samen.Fleet.LocalCredential.Agent` is started lazily by whichever
  process first calls it. Its life must not be tied to that caller: a credential stored
  from a short-lived process (a request, a job, a test) must survive that process
  exiting, including a non-normal exit (`:shutdown`, which ExUnit uses to end a test).
  """
  use ExUnit.Case, async: false

  alias Samen.Fleet.LocalCredential.Agent, as: Store

  @credential %{kind: :shared_secret, secret: "s3cret-bytes"}

  defp stop_store do
    case Process.whereis(Store) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  # Run `fun` in a fresh process that is the FIRST caller (so it starts the store),
  # then end that process with `reason`.
  defp first_call_then_exit(fun, reason) do
    stop_store()
    parent = self()

    pid =
      spawn(fn ->
        fun.()
        send(parent, :called)
        Process.sleep(:infinity)
      end)

    assert_receive :called
    ref = Process.monitor(pid)
    Process.exit(pid, reason)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  setup do
    on_exit(fn -> Store.reset() end)
  end

  test "a credential stored by a process that then shuts down is still there" do
    first_call_then_exit(fn -> :ok = Store.put(:host_a, @credential) end, :shutdown)

    assert {:ok, @credential} = Store.fetch(:host_a)
  end

  test "the store survives its first caller crashing" do
    first_call_then_exit(fn -> :ok = Store.put(:host_b, @credential) end, :kill)

    assert {:ok, @credential} = Store.fetch(:host_b)
  end

  test "positive control: reset clears, and an unknown host is not configured" do
    :ok = Store.put(:host_c, @credential)
    assert {:ok, @credential} = Store.fetch(:host_c)

    Store.reset()
    assert {:error, :not_configured} = Store.fetch(:host_c)
  end
end
