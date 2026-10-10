defmodule Samen.Web.ParamFilterLoggingTest do
  @moduledoc """
  ADR-052 §2.1.2 item 2 — against REAL Phoenix: `Phoenix.Logger.filter_values/2` with the
  framework `{:keep, _}` list keeps the whole value under a kept key, so `id[x]=alice@…` is
  logged in the clear (the positive control proves that leak is real). With
  `Samen.Observability.ParamFilter` installed, Phoenix's own handlers print only scalar values of
  kept keys — driven through Phoenix's real `:telemetry` handlers and captured from the log.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Samen.Observability.ParamFilter

  @secret "alice@example.com"
  @nested %{"id" => %{"x" => @secret}, "org" => %{"name" => "Alice Anders"}, "page" => "2"}

  setup do
    ParamFilter.uninstall()
    on_exit(fn -> ParamFilter.uninstall() end)
    {:ok, keep: Application.fetch_env!(:phoenix, :filter_parameters)}
  end

  defp socket_connected_log(params) do
    capture_log(fn ->
      :telemetry.execute([:phoenix, :socket_connected], %{duration: 1_000}, %{
        log: :error,
        transport: :websocket,
        params: params,
        user_socket: Samen.Web.ParamFilterLoggingTest.Socket,
        result: :ok,
        serializer: Phoenix.Socket.V2.JSONSerializer,
        connect_info: %{},
        vsn: "2.0.0"
      })
    end)
  end

  defp router_dispatch_log(params) do
    capture_log(fn ->
      :telemetry.execute([:phoenix, :router_dispatch, :start], %{system_time: 0}, %{
        log: :error,
        conn: %Plug.Conn{params: params},
        plug: Samen.Web.ParamFilterLoggingTest.Controller,
        plug_opts: :update,
        pipe_through: [:browser],
        route: "/contacts/:id"
      })
    end)
  end

  test "the framework filter is a {:keep, _} list (the shape this proof is about)", %{keep: keep} do
    assert {:keep, [_ | _]} = keep
  end

  test "POSITIVE CONTROL: Phoenix alone logs a nested value under a kept key", %{keep: keep} do
    assert inspect(Phoenix.Logger.filter_values(@nested, keep)) =~ @secret
    assert socket_connected_log(@nested) =~ @secret
    assert router_dispatch_log(@nested) =~ @secret
  end

  test "composed with Phoenix.Logger.filter_values/2, a nested value is filtered", %{keep: keep} do
    filtered = Phoenix.Logger.filter_values(ParamFilter.filter_values(@nested, keep), keep)

    refute inspect(filtered) =~ "lice"
    assert filtered["id"] == %{"x" => "[FILTERED]"}
    assert filtered["page"] == "2"
  end

  test "installed, Phoenix's own handlers print no nested value under a kept key" do
    assert ParamFilter.install() > 0
    assert ParamFilter.installed?()
    # Idempotent: a second install wraps nothing.
    assert ParamFilter.install() == 0

    for log <- [socket_connected_log(@nested), router_dispatch_log(@nested)] do
      refute log =~ "lice"
      assert log =~ ~s("page" => "2")
      assert log =~ "[FILTERED]"
    end
  end

  # ADR-052 §2.4.1 (P3 gate note 6): `install/0` found Phoenix's handlers by owner module and
  # returned 0 when there were none — a Phoenix that MOVED its log handlers would have booted
  # with the nested-value leak back and no signal. It now raises, naming the missing owner.
  test "fails LOUD when an expected Phoenix log handler is not found to wrap" do
    assert ParamFilter.expected_owners() == [Phoenix.Logger, Phoenix.LiveView.Logger]

    lv_handlers =
      for %{function: fun} = h <- :telemetry.list_handlers([:phoenix]),
          Function.info(fun, :module) == {:module, Phoenix.LiveView.Logger},
          do: h

    assert lv_handlers != []
    on_exit(fn -> Phoenix.LiveView.Logger.install() end)
    # Simulate a Phoenix LiveView that attaches its log handlers somewhere we do not look.
    Enum.each(lv_handlers, &:telemetry.detach(&1.id))

    assert_raise ParamFilter.HandlersNotFound, ~r/Phoenix.LiveView.Logger/, fn ->
      ParamFilter.install()
    end

    # Positive control: the owner that IS still there wraps fine when it is all we expect.
    ParamFilter.uninstall()
    assert ParamFilter.install([Phoenix.Logger]) > 0
  end

  test "uninstall restores Phoenix's handlers (the wrap is what closes the leak)" do
    ParamFilter.install()
    assert ParamFilter.uninstall() > 0
    refute ParamFilter.installed?()
    assert socket_connected_log(@nested) =~ @secret
  end
end
