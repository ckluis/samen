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

  test "uninstall restores Phoenix's handlers (the wrap is what closes the leak)" do
    ParamFilter.install()
    assert ParamFilter.uninstall() > 0
    refute ParamFilter.installed?()
    assert socket_connected_log(@nested) =~ @secret
  end
end
