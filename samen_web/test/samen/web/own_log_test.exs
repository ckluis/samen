defmodule Samen.Web.OwnLogTest do
  @moduledoc """
  `Samen.WebTest.OwnLog` captures only the calling process's log lines. It exists because `ExUnit.CaptureLog` captures
  the whole node, so a "this logged nothing" assertion in one async test failed on another test's log
  (`KitStatesTest` "host_nav_extra" vs the metrics controller test's `read=metrics_scrape`).
  """
  use ExUnit.Case, async: true

  require Logger

  alias Samen.WebTest.OwnLog

  test "a line logged by ANOTHER process while the capture runs is not in it; the caller's own line is" do
    parent = self()

    {:ok, other} =
      Task.start_link(fn ->
        receive do
          :go ->
            Logger.error("foreign-process-line read=metrics_scrape")
            send(parent, :foreign_logged)
        end
      end)

    {_result, log} =
      OwnLog.capture(fn ->
        send(other, :go)
        assert_receive :foreign_logged
        Logger.error("own-line read=host_nav_extra")
      end)

    assert log =~ "own-line"
    refute log =~ "foreign-process-line"

    # ANTI-TAUTOLOGY: the node-wide capture the old assertion used DOES see the foreign line
    {:ok, other2} =
      Task.start_link(fn ->
        receive do
          :go ->
            Logger.error("foreign-process-line-2")
            send(parent, :foreign_logged_2)
        end
      end)

    global =
      ExUnit.CaptureLog.capture_log(fn ->
        send(other2, :go)
        assert_receive :foreign_logged_2
      end)

    assert global =~ "foreign-process-line-2"
  end

  # This caller's own capture handlers. Other async tests add and remove their handlers at any time, so the global
  # handler count proves nothing: the handler is found by its owner pid (and so is its id).
  defp own_handler_ids do
    me = self()

    for %{id: id, module: OwnLog.Handler, config: %{pid: ^me}} <- :logger.get_handler_config(), do: id
  end

  test "returns the function's result and removes its handler" do
    assert own_handler_ids() == []

    {{result, [id]}, ""} = OwnLog.capture(fn -> {42, own_handler_ids()} end)

    # the handler existed while the function ran (anti-tautology: the id was really installed) ...
    assert result == 42
    # ... and that very handler is gone afterwards
    assert {:error, {:not_found, ^id}} = :logger.get_handler_config(id)
    assert own_handler_ids() == []
  end

  test "removes its handler when the function raises" do
    me = self()

    assert_raise RuntimeError, "boom", fn ->
      OwnLog.capture(fn ->
        send(me, {:ids, own_handler_ids()})
        raise "boom"
      end)
    end

    assert_received {:ids, [id]}
    assert {:error, {:not_found, ^id}} = :logger.get_handler_config(id)
  end
end
