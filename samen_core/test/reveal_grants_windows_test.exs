defmodule Samen.Reveal.GrantsWindowsTest do
  @moduledoc """
  ARCH-26 (ADR-049 watch-list): the parts of `Samen.Reveal.Grants` that decide whether plaintext is unlocked,
  beyond the single-subject `active?/3` already covered by `reveal_grants_test.exs`:

    * `active_windows/2` and `active_subjects/3` — the SAME requestor-bound, unrevoked, `expires_at > now` gate
      (including the exact-boundary instant: a window ending NOW is closed)
    * `granted?/1` and `granted_many/1` deny a context with no binary subject (fail closed)
    * `write_audit/3` — which org chain a lifecycle row rides, what correlates it, and that a chain failure is
      reported and returned ONLY to a `strict: true` caller
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Samen.Reveal.Context
  alias Samen.Reveal.Grants

  @repo SamenCore.TestRepo

  setup do
    Samen.TestSandbox.shared!(@repo)
    :ok
  end

  defp subj, do: "subject-#{System.unique_integer([:positive])}"
  defp actor, do: "operator-#{System.unique_integer([:positive])}"

  defp grant!(requestor, subject, minutes \\ 30) do
    {:ok, req} = Grants.request(%{subject_id: subject, requestor_id: requestor, reason: "ticket"})
    {:ok, grant} = Grants.approve(req, %{granted_by: actor(), window_minutes: minutes})
    grant
  end

  describe "active_windows/2" do
    test "lists the requestor's own live windows — and only those" do
      me = actor()
      other = actor()
      live = subj()
      revoked = subj()
      expired = subj()
      theirs = subj()

      g_live = grant!(me, live)
      g_revoked = grant!(me, revoked)
      g_expired = grant!(me, expired, 1)
      grant!(other, theirs)
      {:ok, _} = Grants.revoke(g_revoked.id)

      # POSITIVE CONTROL: before the short window ends, the requestor sees live + expired-to-be, not the revoked
      # one and not another operator's.
      before = DateTime.add(g_expired.expires_at, -1, :second)
      subjects = fn now -> me |> Grants.active_windows(now: now) |> Enum.map(& &1.subject_id) |> Enum.sort() end
      assert subjects.(before) == Enum.sort([live, expired])

      assert [%{subject_id: ^live, expires_at: exp}] =
               Grants.active_windows(me, now: g_expired.expires_at) |> Enum.filter(&(&1.subject_id == live))

      assert exp == g_live.expires_at

      # RED: at the EXACT expiry instant the window is closed, and after it too.
      assert subjects.(g_expired.expires_at) == [live]
      assert subjects.(DateTime.add(g_expired.expires_at, 60, :second)) == [live]
      refute other in Enum.map(Grants.active_windows(me), & &1.granted_by)
    end
  end

  describe "active_subjects/3" do
    test "the subset a requestor holds a live window on; closed at the exact expiry instant" do
      me = actor()
      other = actor()
      a = subj()
      b = subj()
      c = subj()
      g_a = grant!(me, a, 1)
      grant!(me, b)
      grant!(other, c)

      all = [a, b, c, subj()]
      assert Grants.active_subjects(me, all, now: DateTime.add(g_a.expires_at, -1, :second)) == MapSet.new([a, b])
      assert Grants.active_subjects(me, all, now: g_a.expires_at) == MapSet.new([b])
      assert Grants.active_subjects(other, all) == MapSet.new([c])
    end
  end

  describe "a context with no binary subject is denied" do
    test "granted?/1 and granted_many/1" do
      me = actor()
      s = subj()
      grant!(me, s)

      live = %Context{actor: me, subject_id: s, resource: SamenCore.Support.RevealDomain.RevealPerson, action: :reveal_email}
      blank = %Context{actor: me, subject_id: nil, resource: SamenCore.Support.RevealDomain.RevealPerson, action: :reveal_email}

      # POSITIVE CONTROL: the live subject is granted by both paths.
      assert Grants.granted?(live)
      assert Grants.granted_many([live]) == [true]

      refute Grants.granted?(blank)
      assert Grants.granted_many([blank, live, blank]) == [false, true, false]
    end
  end

  describe "write_audit/3 — which chain, which correlation, and chain failure" do
    defp chain_rows(subject),
      do:
        @repo.all(from(e in Samen.AuditChain.Entry, where: e.subject_id == ^subject and e.event_type == "grant_lifecycle"))

    defp attrs(extra), do: Map.merge(%{event: "probe", subject_id: subj(), actor_id: actor()}, extra)

    test "with no org_id the row rides the reserved __global__ chain; with one, THAT org's chain" do
      org = Ecto.UUID.generate()

      a = attrs(%{detail: "x"})
      {:ok, _} = Grants.write_audit(@repo, a)
      assert [%{org_id: g}] = chain_rows(a.subject_id)
      assert g == Samen.AuditChain.global_org()

      b = attrs(%{detail: "x", org_id: org})
      {:ok, _} = Grants.write_audit(@repo, b)
      assert [%{org_id: ^org}] = chain_rows(b.subject_id)
    end

    test "the correlation id is the grant id, else the request id, else none" do
      g = Ecto.UUID.generate()
      r = Ecto.UUID.generate()

      for {extra, expected} <- [{%{grant_id: g}, g}, {%{request_id: r}, r}, {%{grant_id: g, request_id: r}, g}, {%{}, nil}] do
        a = attrs(Map.put(extra, :detail, "x"))
        {:ok, _} = Grants.write_audit(@repo, a)
        assert [%{correlation_id: corr}] = chain_rows(a.subject_id)
        assert corr == expected
      end
    end

    test "a row with no detail writes (the detail is optional) and records only the event" do
      a = attrs(%{})
      assert {:ok, _} = Grants.write_audit(@repo, a)
      assert [%{detail: "event=probe " <> _}] = chain_rows(a.subject_id)
    end

    # A repo whose chain-existence probe is down: the lifecycle row (`insert/1`) still lands, the chain write fails.
    defmodule ChainDownRepo do
      @moduledoc false
      def insert(cs), do: SamenCore.TestRepo.insert(cs)
      def in_transaction?, do: SamenCore.TestRepo.in_transaction?()
      def transaction(f), do: SamenCore.TestRepo.transaction(f)
      def rollback(r), do: SamenCore.TestRepo.rollback(r)
      def query!(_sql, _params \\ []), do: raise("probe down")
    end

    test "a failed chain write is REPORTED by org, returned to a strict caller, and swallowed for a lenient one" do
      org = Ecto.UUID.generate()
      a = attrs(%{org_id: org, detail: "x"})

      log = capture_log(fn -> assert {:ok, _} = Grants.write_audit(ChainDownRepo, a) end)
      assert log =~ "read=reveal_audit_chain org=#{org}"
      assert chain_rows(a.subject_id) == []

      # With no org_id the chain probe is asked about the reserved __global__ chain (not about "no org").
      no_org = attrs(%{detail: "x"})
      log = capture_log(fn -> assert {:ok, _} = Grants.write_audit(ChainDownRepo, no_org) end)
      assert log =~ "read=audit_chain_probe org=invalid"
      refute log =~ "read=audit_chain_probe org=unknown"

      capture_log(fn -> assert {:error, _} = Grants.write_audit(ChainDownRepo, a, strict: true) end)
      capture_log(fn -> assert {:ok, _} = Grants.write_audit(ChainDownRepo, a, strict: false) end)
    end
  end
end
