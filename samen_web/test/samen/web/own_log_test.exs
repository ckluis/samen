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

    global = ExUnit.CaptureLog.capture_log(fn -> send(other2, :go) && assert_receive(:foreign_logged_2) end)
    assert global =~ "foreign-process-line-2"
  end

  test "returns the function's result and removes its handler" do
    before = length(:logger.get_handler_ids())
    assert {42, ""} = OwnLog.capture(fn -> 42 end)
    assert length(:logger.get_handler_ids()) == before
  end
end
