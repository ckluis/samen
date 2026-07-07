defmodule Samen.ImpersonationSameTxTest do
  @moduledoc """
  T4.1: the same-transaction auto-expire enqueue + the ExpireWorker reconciliation
  (mirrors T1.6's `reveal_grant_same_tx_test.exs` / `reveal_auto_revoke_test.exs`).

    * `open/1` enqueues `ExpireWorker` (scheduled at `expires_at`) IN THE SAME
      TRANSACTION as the session insert — so a session insert that rolls back leaves
      NO oban_jobs row.
    * At `expires_at` the worker flips `closed_at` and writes an `expired` aud_event
      row — reconciliation, belt-and-suspenders with the deny-on-read policy.
  """
  use ExUnit.Case, async: false

  alias Samen.Impersonation.{Sessions, Session, ExpireWorker}
  alias Samen.OperatorPlane.Actor

  import Ecto.Query, only: [from: 2]

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp op, do: Actor.new("operator-#{System.unique_integer([:positive])}", :operator_support)
  defp org, do: Ecto.UUID.generate()

  test "open/1 enqueues the ExpireWorker scheduled at expires_at (same tx)" do
    o = op()
    g = org()
    {:ok, session} = Sessions.open(%{operator_id: o.id, org_id: g, reason: "same-tx check"})

    jobs =
      @repo.all(
        from(j in "oban_jobs",
          where: j.worker == "Samen.Impersonation.ExpireWorker",
          select: %{args: j.args, scheduled_at: j.scheduled_at}
        )
      )

    job = Enum.find(jobs, fn j -> j.args["session_id"] == session.id end)
    assert job, "expected an ExpireWorker job for the session"
    # Scheduled at (approximately) expires_at. `oban_jobs.scheduled_at` comes back as
    # a NaiveDateTime (no tz) — compare against the naive form of expires_at.
    expires_naive = DateTime.to_naive(session.expires_at)
    assert NaiveDateTime.diff(expires_naive, job.scheduled_at, :second) |> abs() <= 1
  end

  test "the ExpireWorker flips closed_at and writes an expired aud_event row" do
    o = op()
    g = org()
    {:ok, session} = Sessions.open(%{operator_id: o.id, org_id: g, reason: "expire me"})

    assert %Session{closed_at: nil} = Sessions.get(session.id)

    # Run the worker directly (manual Oban mode).
    assert :ok = ExpireWorker.perform(%Oban.Job{args: %{"session_id" => session.id}})

    assert %Session{closed_at: closed, close_cause: "expired"} = Sessions.get(session.id)
    assert closed != nil

    # After the flip, the session is inactive (closed).
    refute Sessions.active?(o.id, g)

    # An `expired` aud_event landed.
    events = Samen.AuditEvent.for_subject(@repo, g)
    assert Enum.any?(events, &(&1.detail =~ "event=expired"))
  end

  test "the ExpireWorker is idempotent on an already-closed session" do
    o = op()
    g = org()
    {:ok, session} = Sessions.open(%{operator_id: o.id, org_id: g, reason: "x"})
    {:ok, _} = Sessions.close(session.id)

    # A second expire is a no-op (does not error, does not re-flip).
    assert :ok = ExpireWorker.perform(%Oban.Job{args: %{"session_id" => session.id}})
    assert %Session{close_cause: "manual"} = Sessions.get(session.id)
  end
end
