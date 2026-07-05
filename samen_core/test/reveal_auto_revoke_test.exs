defmodule Samen.Reveal.AutoRevokeTest do
  @moduledoc """
  T1.6 clause (d): the auto-revoke job flips the grant to revoked at expires_at.

  Uses Oban's :manual testing mode: `Oban.drain_queue/2` runs the scheduled
  job(s) synchronously so we can observe the flip. The deny-on-read policy
  (clause (c)) already denies past expires_at regardless of this job — this test
  proves the job DOES reconcile the row to `revoked`.
  """
  use ExUnit.Case, async: false

  alias Samen.Reveal.Grants
  alias Samen.Reveal.RevealGrant

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  test "draining the :reveal queue runs the auto-revoke job and flips revoked_at" do
    s = subj()
    requestor = actor()
    approver = actor()
    {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
    # Window in the past so the scheduled job is due immediately on drain.
    {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 5})

    assert @repo.get(RevealGrant, grant.id).revoked_at == nil

    # with_scheduled: true runs jobs scheduled for the future too.
    %{success: n} = Oban.drain_queue(queue: :reveal, with_scheduled: true)
    assert n >= 1

    revoked = @repo.get(RevealGrant, grant.id)
    assert revoked.revoked_at != nil
    # expires_at is UNCHANGED — auto-revoke never renews (clause (e)).
    assert revoked.expires_at == grant.expires_at

    events = Grants.audit_for(s) |> Enum.map(& &1.event)
    assert "expired" in events
  end

  test "auto-revoke is idempotent — a manually-revoked grant is left as-is" do
    s = subj()
    requestor = actor()
    approver = actor()
    {:ok, req} = Grants.request(%{subject_id: s, requestor_id: requestor, reason: "r"})
    {:ok, grant} = Grants.approve(req, %{granted_by: approver, window_minutes: 5})

    {:ok, manually_revoked} = Grants.revoke(grant.id, %{actor_id: "human-op"})
    manual_ts = manually_revoked.revoked_at

    %{} = Oban.drain_queue(queue: :reveal, with_scheduled: true)

    # revoked_at is the MANUAL timestamp — the job did not overwrite it.
    assert @repo.get(RevealGrant, grant.id).revoked_at == manual_ts
  end
end
