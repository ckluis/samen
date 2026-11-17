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

  # A write that did not happen reported through the 3-arity form is counted as a READ failure (the form hard-codes
  # `:read`). Op names that say they are a write (an audit row, an insert, an append, a partition move, ...) must go
  # through `report_write/3` (or `report(:write, ...)`).
  @write_op ~r/(_audit|_audit_deferral|_audit_trip|_audit_switch|_audit_chain|_insert|_append_row|_move|_undo|_emit_blocked_audit|_auto_suspend|_notify_\w+|_notify_accept)$/

  test "RED: no 3-arity Failure.report names a WRITE op (it would count a failed write as a read); report_write is used for them (control)" do
    lib = Path.expand("../lib", __DIR__)
    files = Path.wildcard(Path.join(lib, "**/*.ex"))

    reads = for f <- files, [_, name] <- Regex.scan(~r/Failure\.report\(:(\w+),/, File.read!(f)), do: {Path.relative_to(f, lib), name}
    writes = for f <- files, [_, name] <- Regex.scan(~r/Failure\.report_write\(:(\w+),/, File.read!(f)), do: name

    # POSITIVE CONTROL: the scan sees both forms, and the write-op pattern matches real write sites
    assert length(reads) > 20
    assert "suspension_audit" in writes and "budget_auto_suspend" in writes
    assert Enum.all?(~w(suspension_audit budget_auto_suspend archival_audit audit_partition_move), &(&1 =~ @write_op))
    refute "audit_chain_reveal_events" =~ @write_op

    misreported = for {file, name} <- reads, name =~ @write_op, do: {file, name}
    assert misreported == []
  end
end
