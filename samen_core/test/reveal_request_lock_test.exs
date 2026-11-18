defmodule Samen.Reveal.RequestLockTest do
  @moduledoc """
  The row lock every reveal decision takes on its request (`SELECT … FOR UPDATE`, ADR-040 §4.7), proven with TWO real
  connections (the shared sandbox is one connection, so this module runs the pool in `:auto`).

  A holder transaction takes the lock on a committed request row and keeps it; a second connection, with a short
  `lock_timeout`, tries to decide (approve, deny) or re-open the same request. Without the lock the second connection
  never waits: the request is already `approved`, so `approve`/`deny` answer `:not_pending` at once and the re-open
  `:skipped`. WITH the lock it waits and Postgres aborts it (`lock_not_available`), which the kernel answers as
  `{:error, :unavailable}` (reported, never retried, never raised).

  NOTHING is left committed but the one request row, deleted on exit: the holder rolls back, and every decision the
  second connection attempts runs inside a transaction it rolls back (a committed audit row would break the append-only
  `Samen.AuditChainTest`).
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Samen.Reveal.Grants
  alias Samen.Reveal.RevealRequest

  @repo SamenCore.TestRepo

  setup do
    Samen.TestSandbox.auto!(@repo)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    org = Ecto.UUID.generate()

    req =
      @repo.insert!(%RevealRequest{
        subject_id: "lock-subject-#{System.unique_integer([:positive])}",
        requestor_id: "lock-requestor",
        reason: "ticket 500: lock proof",
        # decided: any decision that gets past the lock is refused at once, so nothing it could write is at stake
        status: "approved",
        org_id: org,
        inserted_at: now,
        updated_at: now
      })

    on_exit(fn -> @repo.delete_all(from(q in RevealRequest, where: q.id == ^req.id)) end)
    {:ok, req: req, org: org}
  end

  # A transaction on its own connection that takes the row lock the way a decision would (plain SQL, independent of the
  # code under test), tells the test, and holds it until released. It rolls back.
  defp hold_lock(req) do
    parent = self()

    task =
      Task.async(fn ->
        @repo.transaction(fn ->
          @repo.all(from(q in RevealRequest, where: q.id == ^req.id, lock: "FOR UPDATE"))
          send(parent, :locked)

          receive do
            :release -> :ok
          after
            10_000 -> :timed_out
          end

          @repo.rollback(:held)
        end)
      end)

    assert_receive :locked, 5_000
    task
  end

  defp release(task) do
    send(task.pid, :release)
    assert {:error, :held} = Task.await(task)
  end

  # `fun` on a SECOND connection, inside a transaction that is always rolled back, with a short lock_timeout.
  defp contend(fun) do
    Task.async(fn ->
      {:error, result} =
        @repo.transaction(fn ->
          @repo.query!("SET LOCAL lock_timeout = '150ms'")
          @repo.rollback(fun.())
        end)

      result
    end)
    |> Task.await()
  end

  defp attempts(req, org) do
    [
      approve: fn -> Grants.approve(req.id, %{granted_by: "lock-approver", org_id: org, repo: @repo}) end,
      deny: fn -> Grants.deny(req.id, %{denied_by: "lock-approver", org_id: org, repo: @repo}) end,
      reopen: fn -> Grants.reopen_orphan(req, org, @repo, []) end
    ]
  end

  test "CONTROL: with no holder the same attempts are not made to wait: decided request, refused at once", %{req: req, org: org} do
    outcomes = for {name, fun} <- attempts(req, org), do: {name, contend(fun)}

    assert outcomes == [approve: {:error, :not_pending}, deny: {:error, :not_pending}, reopen: :skipped]
  end

  test "approve, deny and re-open WAIT for a request another connection holds, and are reported unavailable (no raise)", %{req: req, org: org} do
    holder = hold_lock(req)

    log =
      capture_log(fn ->
        outcomes = for {name, fun} <- attempts(req, org), do: {name, contend(fun)}

        assert outcomes == [approve: {:error, :unavailable}, deny: {:error, :unavailable}, reopen: :failed]
      end)

    # said by name, with the structured code (never the row, never a value)
    assert log =~ "write=reveal_decision_lock"
    assert log =~ "cause=lock_not_available"
    assert log =~ "write=reveal_open_engine_approval"

    release(holder)

    # released: the same attempts get through to their own refusal
    assert [approve: {:error, :not_pending}, deny: {:error, :not_pending}, reopen: :skipped] ==
             for({name, fun} <- attempts(req, org), do: {name, contend(fun)})
  end

  test "a decision aborted on the lock changed nothing: the request and its grants are as they were", %{req: req, org: org} do
    holder = hold_lock(req)
    capture_log(fn -> assert {:error, :unavailable} = contend(Keyword.fetch!(attempts(req, org), :approve)) end)
    release(holder)

    assert @repo.get!(RevealRequest, req.id).status == "approved"
    assert @repo.all(from(g in Samen.Reveal.RevealGrant, where: g.request_id == ^req.id)) == []
  end
end
