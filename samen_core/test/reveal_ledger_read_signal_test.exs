defmodule Samen.RevealLedgerReadSignalTest do
  @moduledoc """
  O10 — the tenant reveal-access ledger read distinguishes "no reveals" (legitimately
  empty, `{:ok, []}`) from "the read FAILED" (`{:error, :unavailable}`), so a failing
  ledger read is never silently shown as a clean, empty ledger on a tenant TRUST surface.

  Positive controls (anti-tautology): a genuinely-empty ledger returns empty-OK and a
  populated ledger returns its events — the error signal is about the READ, not the org.
  """
  use ExUnit.Case, async: false

  alias SamenCore.TestRepo, as: Repo
  alias Samen.AuditChain

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {:ok, org: "org-#{System.unique_integer([:positive])}"}
  end

  # A repo whose read RAISES — models a host that has not migrated `aud_chain`, or a DB
  # outage. The rescue in `reveal_events_result/2` must surface this as a DISTINCT error.
  defmodule RaisingRepo do
    def all(_q), do: raise(RuntimeError, ~s(relation "aud_chain" does not exist))
  end

  defp append_reveal!(org) do
    {:ok, e} =
      AuditChain.append(
        %{
          org_id: org,
          event_type: "grant_lifecycle",
          subject_id: "subj-#{System.unique_integer([:positive])}",
          actor_id: "op-1",
          detail: "event=requested ticket 1"
        },
        repo: Repo
      )

    e
  end

  describe "genuine empty is empty-OK (never an error)" do
    test "an org with no reveals returns {:ok, []}", %{org: org} do
      assert {:ok, []} = AuditChain.reveal_events_result(org, repo: Repo)
    end

    test "the reserved __global__ partition is empty-OK, never surfaced to a tenant" do
      assert {:ok, []} = AuditChain.reveal_events_result(AuditChain.global_org(), repo: Repo)
    end
  end

  describe "a populated ledger returns its events (positive control)" do
    test "returns the org's grant_lifecycle events", %{org: org} do
      e = append_reveal!(org)
      assert {:ok, events} = AuditChain.reveal_events_result(org, repo: Repo)
      assert Enum.any?(events, &(&1.subject_id == e.subject_id))
    end
  end

  describe "a READ FAILURE is a DISTINCT signal, never masked as empty (O10)" do
    test "a failing ledger read returns {:error, :unavailable}, NOT {:ok, []}", %{org: org} do
      assert {:error, :unavailable} = AuditChain.reveal_events_result(org, repo: RaisingRepo)

      # Anti-tautology: the SAME org read through a WORKING repo is empty-OK, so the error
      # is genuinely about the READ failing, not about the org having no reveals.
      assert {:ok, []} = AuditChain.reveal_events_result(org, repo: Repo)
    end

    test "the back-compat list form degrades error → [] (documented; non-surface callers only)",
         %{org: org} do
      # The list projection intentionally collapses the distinction — which is exactly why
      # tenant TRUST surfaces must use reveal_events_result/2 (the honest one) instead.
      assert [] = AuditChain.reveal_events_for_org(org, repo: RaisingRepo)
    end
  end
end
