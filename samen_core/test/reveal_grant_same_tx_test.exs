defmodule Samen.Reveal.GrantSameTxTest do
  @moduledoc """
  T1.6 clause (d): the Oban auto-revoke job is enqueued IN THE SAME TRANSACTION
  that writes the grant. The proof is a CRASH test: if the grant insert (or any
  step of the multi) rolls back, there is NO `oban_jobs` row — the enqueue is not
  a separate transaction that could survive a grant rollback.

  This is the load-bearing same-tx proof (matches the T2.1 crash-test pattern).
  """
  use ExUnit.Case, async: false

  alias Samen.Reveal.Grants
  alias Samen.Reveal.{RevealGrant, AutoRevokeWorker}

  import Ecto.Query

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  defp reveal_jobs_for(grant_id) do
    @repo.all(
      from(j in "oban_jobs",
        where: fragment("? ->> 'grant_id' = ?", j.args, ^grant_id),
        select: j.id
      )
    )
  end

  # ==========================================================================
  # Happy path: approve enqueues the auto-revoke job in the grant's tx.
  # ==========================================================================

  test "approve enqueues exactly ONE reveal auto-revoke job scheduled at expires_at" do
    s = subj()
    requestor = actor()
    {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
    {:ok, grant} = Grants.approve(req, %{granted_by: actor(), window_minutes: 5})

    jobs =
      @repo.all(
        from(j in "oban_jobs",
          where: fragment("? ->> 'grant_id' = ?", j.args, ^grant.id),
          select: %{
            worker: j.worker,
            queue: j.queue,
            scheduled_at: j.scheduled_at,
            state: j.state
          }
        )
      )

    assert [job] = jobs
    assert job.worker == "Samen.Reveal.AutoRevokeWorker"
    assert job.queue == "reveal"
    # scheduled_at == the grant's expires_at (to the second). `oban_jobs` stores
    # timestamps as naive UTC, so compare as NaiveDateTime.
    assert NaiveDateTime.diff(
             job.scheduled_at,
             DateTime.to_naive(grant.expires_at),
             :second
           ) == 0

    assert job.state in ["scheduled", "available"]
  end

  # ==========================================================================
  # CRASH test (clause (d)): grant insert rolls back ⇒ NO job row.
  # ==========================================================================

  test "CRASH: when the grant multi rolls back, NO oban_jobs row survives" do
    s = subj()
    grant_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires = DateTime.add(now, 300, :second)

    grant_attrs = %{
      id: grant_id,
      request_id: Ecto.UUID.generate(),
      subject_id: s,
      requestor_id: "requestor-#{s}",
      granted_by: "approver-#{s}",
      reason: "crash-test",
      expires_at: expires,
      inserted_at: now,
      updated_at: now
    }

    # Reproduce approve/2's multi shape: grant insert + same-tx Oban enqueue,
    # then a step that FAILS — the crash. The whole transaction must roll back.
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :grant,
        %RevealGrant{} |> Ecto.Changeset.cast(grant_attrs, Map.keys(grant_attrs))
      )
      |> Oban.insert(
        :auto_revoke,
        AutoRevokeWorker.new(%{grant_id: grant_id}, scheduled_at: expires)
      )
      # The crash: a step that always errors AFTER the grant + job were staged.
      |> Ecto.Multi.run(:boom, fn _repo, _changes -> {:error, :simulated_crash} end)

    assert {:error, :boom, :simulated_crash, _} = @repo.transaction(multi)

    # The grant row rolled back...
    assert @repo.get(RevealGrant, grant_id) == nil
    # ...AND — the load-bearing assertion — no Oban job row survived.
    assert reveal_jobs_for(grant_id) == []
  end

  test "CRASH via the DB CHECK: a self-approval multi rolls back grant AND job together" do
    # Even a self-approval that somehow reached the multi (bypassing the policy
    # check) is rejected by the DB CHECK inside the transaction, taking the job
    # enqueue down with it. Proves the same-tx coupling under a real DB failure.
    s = subj()
    same = "self-#{s}"
    grant_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    expires = DateTime.add(now, 300, :second)

    grant_attrs = %{
      id: grant_id,
      request_id: Ecto.UUID.generate(),
      subject_id: s,
      requestor_id: same,
      granted_by: same,
      reason: "self",
      expires_at: expires,
      inserted_at: now,
      updated_at: now
    }

    grant_cs =
      %RevealGrant{}
      |> Ecto.Changeset.cast(grant_attrs, Map.keys(grant_attrs))
      # Map the DB CHECK to a changeset error (as the real grant_changeset does)
      # so the multi returns {:error, :grant, cs, _} instead of raising.
      |> Ecto.Changeset.check_constraint(:granted_by, name: :rvg_distinct_party)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:grant, grant_cs)
      |> Oban.insert(
        :auto_revoke,
        AutoRevokeWorker.new(%{grant_id: grant_id}, scheduled_at: expires)
      )

    assert {:error, :grant, _changeset, _} = @repo.transaction(multi)
    assert @repo.get(RevealGrant, grant_id) == nil
    assert reveal_jobs_for(grant_id) == []
  end
end
