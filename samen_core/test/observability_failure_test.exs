defmodule Samen.Observability.FailureTest do
  @moduledoc """
  The kernel's value-free failure report (`Samen.Observability.Failure`): one log line and one telemetry event
  carrying the operation NAME, a canonical-UUID org and the exception MODULE names — never a message, a struct,
  a value or a raw parameter. `Samen.Web.Reads.Guard.report/3` delegates to it.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Samen.Observability.Failure

  @org "0b0d6c1e-2f5a-4c3e-9a41-7d1c2f3e4a5b"
  @secret "jane.doe@example.com"

  defp boom, do: %Ash.Error.Unknown{errors: [%Ash.Error.Unknown.UnknownError{error: @secret}]}

  test "reports the name, the org and the exception module names — and nothing else" do
    log = capture_log(fn -> assert :ok = Failure.report(:probe, %{actor: %{org_id: @org}}, boom()) end)

    assert log =~ "read failed read=probe org=#{@org} cause=Ash.Error.Unknown"
    assert log =~ "Ash.Error.Unknown.UnknownError"
    refute log =~ @secret
  end

  test "a failed write is reported as a write, with its own telemetry event" do
    id = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      id,
      [:samen, :core, :write, :error],
      fn _e, m, meta, _ -> send(parent, {:event, m, meta}) end,
      nil
    )

    log = capture_log(fn -> Failure.report(:write, :put_thing, @org, ArgumentError.exception(@secret), []) end)
    :telemetry.detach(id)

    assert log =~ "write failed write=put_thing org=#{@org} cause=ArgumentError"
    refute log =~ @secret
    assert_receive {:event, %{count: 1}, %{write: :put_thing, cause: "ArgumentError"}}
  end

  test "a forged org id cannot inject a log line; an atom reason is named; an unknown shape is 'unknown'" do
    forged = "x\n[error] cause=forged org=" <> String.duplicate("a", 40)

    log =
      capture_log(fn ->
        Failure.report(:forge, forged, :exit)
        Failure.report(:odd, nil, {:weird, @secret})
      end)

    assert log =~ "read=forge org=invalid cause=exit"
    assert log =~ "read=odd org=unknown cause=unknown"
    refute log =~ "cause=forged"
    refute log =~ @secret
  end

  test "custom tag and event prefix are honoured (the web layer's compatibility seam)" do
    log = capture_log(fn -> Failure.report(:read, :tagged, @org, ArgumentError.exception("x"), tag: "[Samen.Web.Reads]", event_prefix: [:samen, :web]) end)
    assert log =~ "[Samen.Web.Reads] read failed read=tagged"
  end
end
