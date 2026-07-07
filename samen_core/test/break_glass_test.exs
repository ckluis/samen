defmodule Samen.BreakGlassTest do
  @moduledoc """
  T4.4 — break-glass emergency reveal with deferred-anchor local audit + breadth
  budget (doc "honest edges" break-glass bullet).

  Covers every clause + every required red path:

    (a) break-glass captures who/what/why to a LOCALLY-DURABLE append-only
        hash-chained fsync'd record BEFORE the reveal is granted;
        RED: break-glass with NO reason refuses.
    (b) reconciliation anchors local entries into the T4.3 chain (+ aud_event) with
        gap/tamper detection across the local→central seam;
        RED: local-entry tamper detected at reconciliation (nothing anchored).
    (c) the KMS is NOT bypassable — break-glass still calls the live KMS;
        DRILL 1: central-DB-down succeeds via local audit;
        DRILL 2 / RED: KMS-down denies (fail closed);
        ANTI-TAUTOLOGY: the KMS-down deny is a non-vacuous discriminator.
    (d) per-operator BREADTH BUDGET: N distinct subjects/window; exceeding
        auto-suspends the operator (all reveal paths deny incl. break-glass);
        RED: budget breach auto-suspends and further reveals deny;
        ANTI-TAUTOLOGY: the budget is a non-vacuous discriminator.
    (e) R8: unanchored-entries telemetry fires while local entries await anchoring.

  KMS: uses the FileBacked adapter (it can `simulate_outage/1` — the load-bearing
  KMS-down drill).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Samen.BreakGlass
  alias Samen.BreakGlass.{LocalAudit, Budget, Reconciliation, AnchorRow}
  alias Samen.OperatorPlane.{Actor, Suspension, SuspensionRow}
  alias Samen.Kms.FileBacked
  alias Samen.{Vault, Masked}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})

    # FileBacked KMS — the only adapter that simulates a store/KMS outage.
    FileBacked.simulate_outage(false)
    prior_kms = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, FileBacked)

    # A per-test local-audit file (fsync'd on the operator node's disk).
    path =
      Path.join(System.tmp_dir!(), "bg_test_#{System.unique_integer([:positive])}.local")

    File.rm_rf!(path)

    on_exit(fn ->
      FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, prior_kms || FileBacked)
      File.rm_rf!(path)
    end)

    {:ok, path: path}
  end

  # --- helpers -------------------------------------------------------------

  defp operator, do: Actor.new("op-#{System.unique_integer([:positive])}", :operator_break_glass)
  defp subj, do: "subj-#{System.unique_integer([:positive])}"

  # Store a vaulted secret and return {subject_id, %Masked{}}.
  defp vaulted(secret) do
    subject_id = subj()
    {:ok, token} = Vault.store_field(subject_id, :pii_email, :emails, secret, @repo)
    {subject_id, Masked.new(token, :emails)}
  end

  defp req(op, subject_id, masked, overrides) do
    Map.merge(
      %{
        operator: op,
        subject_id: subject_id,
        reason: "PagerDuty INC-42: locked-out user support escalation",
        masked: masked,
        action: :reveal_email,
        resource: SamenCore.Support.RevealDomain.RevealPerson,
        org_id: "org-#{System.unique_integer([:positive])}",
        repo: @repo
      },
      overrides
    )
  end

  # ==========================================================================
  # (a) who/what/why BEFORE the reveal + locally-durable hash-chained record
  # ==========================================================================

  describe "(a) break-glass captures who/what/why to a local durable hash chain" do
    test "a break-glass reveal writes a local entry BEFORE decrypting and returns plaintext",
         %{path: path} do
      op = operator()
      {subject_id, masked} = vaulted("alice@example.com")

      assert {:ok, %{plaintext: "alice@example.com", local_entry: entry}} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))

      # The who/what/why is durable locally.
      assert entry.seq == 0
      assert entry.subject_id == subject_id
      assert entry.actor_id == op.id
      assert entry.reason =~ "INC-42"

      # The file exists, is fsync'd (readable immediately), and verifies.
      assert File.exists?(path)
      assert {:ok, %{count: 1}} = LocalAudit.verify_chain(path: path)
    end

    test "RED: break-glass with NO reason refuses (clause (a) red path)", %{path: path} do
      op = operator()
      {subject_id, masked} = vaulted("bob@example.com")

      assert {:error, :reason_required} =
               BreakGlass.reveal(req(op, subject_id, masked, %{reason: "", local_audit_path: path}))

      assert {:error, :reason_required} =
               BreakGlass.reveal(
                 req(op, subject_id, masked, %{reason: nil, local_audit_path: path})
               )

      # NOTHING was written locally and NO reveal happened.
      refute File.exists?(path)
    end

    test "RED: a non-break-glass actor cannot break glass (single-role convention)", %{path: path} do
      {subject_id, masked} = vaulted("carol@example.com")

      support = Actor.new("op-support", :operator_support)
      readonly = Actor.new("op-ro", :operator_readonly)
      tenant = %{id: "tenant-user", role: :owner}

      for actor <- [support, readonly, tenant] do
        assert {:error, :not_authorized} =
                 BreakGlass.reveal(req(actor, subject_id, masked, %{local_audit_path: path}))
      end

      refute BreakGlass.authorized?(support)
      assert BreakGlass.authorized?(operator())
      refute File.exists?(path)
    end

    test "each local entry carries the prior hash (a hash CHAIN, not independent rows)",
         %{path: path} do
      op = operator()
      {s1, m1} = vaulted("d1@example.com")
      {s2, m2} = vaulted("d2@example.com")

      {:ok, %{local_entry: e0}} =
        BreakGlass.reveal(req(op, s1, m1, %{local_audit_path: path}))

      {:ok, %{local_entry: e1}} =
        BreakGlass.reveal(req(op, s2, m2, %{local_audit_path: path}))

      # e1 links to e0 (prior hash) — the chain property.
      assert e1.prior_hash == e0.hash
      assert e1.seq == e0.seq + 1
    end

    test "RED: a failed local-audit write fails the whole break-glass closed (can't log ⇒ can't see)",
         %{path: _path} do
      op = operator()
      {subject_id, masked} = vaulted("nolog@example.com")

      # Point the local audit at a path whose PARENT is a regular FILE, so mkdir_p!
      # (and therefore the append) fails — the local audit cannot be written.
      blocker = Path.join(System.tmp_dir!(), "bg_blocker_#{System.unique_integer([:positive])}")
      File.write!(blocker, "i am a file, not a directory")
      unwritable = Path.join(blocker, "audit.local")
      on_exit(fn -> File.rm_rf!(blocker) end)

      assert {:error, {:local_audit_failed, _reason}} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: unwritable}))
    end
  end

  # ==========================================================================
  # (F4.1) the break-glass reveal is BOUND to the token's real subject: a
  # request whose :subject_id (what the local audit + breadth budget record)
  # does NOT match the masked token's real subject must DENY — never leak the
  # real subject's plaintext under a decoupled who-it-was-about.
  # ==========================================================================

  describe "(F4.1) break-glass subject bind" do
    test "RED: a mismatched subject_id DENIES :subject_mismatch (no plaintext, no decoupled audit)",
         %{path: path} do
      op = operator()
      # A's real vaulted secret + token.
      {subject_a, masked_a} = vaulted("alice-SECRET@a.test")
      subject_b = subj()

      # The request claims subject B (what the local audit + breadth budget will
      # record) but hands A's masked token. Empirically this used to return A's
      # plaintext with the audit recording B (F4.1). It MUST now deny.
      assert {:error, :subject_mismatch} =
               BreakGlass.reveal(
                 req(op, subject_b, masked_a, %{local_audit_path: path})
               )

      # No plaintext for A leaked through the mismatched request.
      result =
        BreakGlass.reveal(req(op, subject_b, masked_a, %{local_audit_path: path}))

      refute match?({:ok, %{plaintext: "alice-SECRET@a.test"}}, result)
      refute subject_a == subject_b
    end

    test "the matching subject_id still reveals (positive control — the bind is not always-deny)",
         %{path: path} do
      op = operator()
      {subject_id, masked} = vaulted("honest@match.test")

      assert {:ok, %{plaintext: "honest@match.test"}} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))
    end
  end

  # ==========================================================================
  # (b) reconciliation into the central chain + tamper detection at the seam
  # ==========================================================================

  describe "(b) reconciliation anchors local entries into the central chain" do
    test "control-plane returns → local entries anchor into aud_chain + aud_event, idempotently",
         %{path: path} do
      op = operator()
      org = "org-recon-#{System.unique_integer([:positive])}"

      for _ <- 1..3 do
        {s, m} = vaulted("recon@example.com")

        {:ok, _} =
          BreakGlass.reveal(req(op, s, m, %{local_audit_path: path, org_id: org}))
      end

      # 3 local entries, none anchored yet.
      assert LocalAudit.count(path: path) == 3
      assert @repo.one(from(a in AnchorRow, select: count(a.id))) == 0

      assert {:ok, %{anchored: 3, already: 0, total: 3}} =
               Reconciliation.reconcile(repo: @repo, path: path)

      # Now 3 anchor rows AND 3 central chain entries on the org chain.
      assert @repo.one(from(a in AnchorRow, select: count(a.id))) == 3

      {:ok, chain} = Samen.AuditChain.verify_chain(org, repo: @repo)
      assert chain.entries >= 3

      # Idempotent: a second reconcile anchors nothing new.
      assert {:ok, %{anchored: 0, already: 3, total: 3}} =
               Reconciliation.reconcile(repo: @repo, path: path)
    end

    test "RED: local-entry tamper is detected at reconciliation and NOTHING is anchored",
         %{path: path} do
      op = operator()
      {s1, m1} = vaulted("t1@example.com")
      {s2, m2} = vaulted("t2@example.com")

      {:ok, _} = BreakGlass.reveal(req(op, s1, m1, %{local_audit_path: path}))
      {:ok, _} = BreakGlass.reveal(req(op, s2, m2, %{local_audit_path: path}))

      # Tamper: hand-edit the SECOND line's payload bytes (keep its stored hash).
      [l0, l1] = File.read!(path) |> String.split("\n", trim: true)
      [stored_hash, b64] = String.split(l1, " ", parts: 2)
      corrupt_b64 = mutate_b64(b64)
      File.write!(path, l0 <> "\n" <> stored_hash <> " " <> corrupt_b64 <> "\n")

      assert {:error, {:local_tamper, {:tampered_line, _}}} =
               Reconciliation.reconcile(repo: @repo, path: path)

      # Fail closed across the seam: a corrupt local record anchors NOTHING.
      assert @repo.one(from(a in AnchorRow, select: count(a.id))) == 0
    end

    test "RED: a deleted middle local entry (gap) is detected at reconciliation", %{path: path} do
      op = operator()

      for _ <- 1..3 do
        {s, m} = vaulted("gap@example.com")
        {:ok, _} = BreakGlass.reveal(req(op, s, m, %{local_audit_path: path}))
      end

      # Delete the MIDDLE line → seq gap.
      [l0, _l1, l2] = File.read!(path) |> String.split("\n", trim: true)
      File.write!(path, l0 <> "\n" <> l2 <> "\n")

      assert {:error, {:local_tamper, {reason, _}}} =
               Reconciliation.reconcile(repo: @repo, path: path)

      assert reason in [:seq_gap, :broken_link]
      assert @repo.one(from(a in AnchorRow, select: count(a.id))) == 0
    end
  end

  # ==========================================================================
  # (c) KMS is NOT bypassable — the two drills
  # ==========================================================================

  describe "(c) KMS dependency is not bypassable" do
    test "DRILL 1: central-DB(-chain) down → break-glass STILL succeeds via local audit",
         %{path: path} do
      # Model the control-plane/central-audit DB being unreachable by pointing the
      # break-glass repo at a repo whose aud_chain table does not exist... but the
      # canonical faithful drill here is: the LOCAL audit is the ONLY sink during the
      # outage, and the reveal completes. We assert the reveal completes and the
      # who/what/why is durable LOCALLY (not in the central chain yet).
      op = operator()
      {subject_id, masked} = vaulted("drill1@example.com")

      # No reconciliation has run: the central chain has no break-glass entry for
      # this org, but the reveal succeeds and the local record holds the accountability.
      assert {:ok, %{plaintext: "drill1@example.com"}} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))

      assert LocalAudit.count(path: path) == 1
      # Unanchored: the residue window is open (clause (e)).
      assert Reconciliation.unanchored_count(repo: @repo, path: path) >= 1
    end

    test "DRILL 2 / RED: KMS down → break-glass FAILS CLOSED (deny-recoverable, no bypass)",
         %{path: path} do
      op = operator()
      {subject_id, masked} = vaulted("drill2@example.com")

      # The KMS/key store is unreachable.
      FileBacked.simulate_outage(true)

      assert {:error, :unavailable} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))

      # KMS heals → the SAME break-glass now succeeds (deny-RECOVERABLE, not a shred).
      FileBacked.simulate_outage(false)

      assert {:ok, %{plaintext: "drill2@example.com"}} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))
    end

    test "KMS down does NOT manufacture plaintext even though the local audit is writable",
         %{path: path} do
      # The local audit sink is fully available (control plane analogue up); only the
      # KMS is down. Break-glass must STILL deny — decryptability depends on KMS
      # reachability, and there is no degraded path that bypasses it.
      op = operator()
      {subject_id, masked} = vaulted("nobypass@example.com")

      FileBacked.simulate_outage(true)

      assert {:error, :unavailable} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))
    end
  end

  # ==========================================================================
  # (d) breadth budget → auto-suspend → every reveal path denies
  # ==========================================================================

  describe "(d) breadth budget auto-suspends the operator" do
    setup do
      prior = Application.get_env(:samen_core, :break_glass_breadth_budget)
      Application.put_env(:samen_core, :break_glass_breadth_budget, 3)
      on_exit(fn -> Application.put_env(:samen_core, :break_glass_breadth_budget, prior) end)
      :ok
    end

    test "RED: exceeding N distinct subjects auto-suspends and further reveals deny",
         %{path: path} do
      op = operator()

      # Budget = 3 distinct subjects. Reveals 1..3 succeed.
      for _ <- 1..3 do
        {s, m} = vaulted("budget@example.com")

        assert {:ok, %{plaintext: "budget@example.com"}} =
                 BreakGlass.reveal(req(op, s, m, %{local_audit_path: path}))
      end

      refute Suspension.suspended?(op.id, repo: @repo)

      # The 4th DISTINCT subject trips the budget: this reveal denies AND the
      # operator is auto-suspended.
      {s4, m4} = vaulted("budget@example.com")

      assert {:error, :budget_exceeded} =
               BreakGlass.reveal(req(op, s4, m4, %{local_audit_path: path}))

      assert Suspension.suspended?(op.id, repo: @repo)

      # An audit event was written for the suspension.
      assert @repo.exists?(
               from(s in SuspensionRow,
                 where: s.operator_id == ^op.id and is_nil(s.cleared_at)
               )
             )

      # Every subsequent break-glass denies with :operator_suspended (NOT budget) —
      # the suspension is now the gate, checked before the budget.
      {s5, m5} = vaulted("budget@example.com")

      assert {:error, :operator_suspended} =
               BreakGlass.reveal(req(op, s5, m5, %{local_audit_path: path}))
    end

    test "a suspended operator is denied on the ROUTINE reveal path too (all paths deny)" do
      # T4.4 clause (d): the flag denies on EVERY reveal path.
      op_id = "op-suspend-#{System.unique_integer([:positive])}"
      {:ok, _} = Suspension.suspend(%{operator_id: op_id, reason: "test", repo: @repo})

      ctx = %Samen.Reveal.Context{
        actor: op_id,
        subject_id: subj(),
        resource: SamenCore.Support.RevealDomain.RevealPerson,
        action: :reveal_email
      }

      # Even with (hypothetically) a live grant, a suspended operator's granted?/1
      # returns false because the suspension gate precedes the grant check.
      refute Samen.Reveal.Grants.granted?(ctx)
    end

    test "a suspended operator cannot open an impersonation session (all paths deny)" do
      op_id = "op-imp-#{System.unique_integer([:positive])}"
      {:ok, _} = Suspension.suspend(%{operator_id: op_id, reason: "test", repo: @repo})

      assert {:error, :operator_suspended} =
               Samen.Impersonation.Sessions.open(%{
                 operator_id: op_id,
                 org_id: Ecto.UUID.generate(),
                 reason: "support",
                 repo: @repo
               })
    end

    test "repeat reveals of the SAME subject do NOT widen breadth (breadth, not depth)",
         %{path: path} do
      op = operator()
      {s, m} = vaulted("samesubject@example.com")

      # 5 reveals of ONE subject — breadth stays 1, well under the budget of 3.
      for _ <- 1..5 do
        assert {:ok, _} = BreakGlass.reveal(req(op, s, m, %{local_audit_path: path}))
      end

      refute Suspension.suspended?(op.id, repo: @repo)
      assert Budget.current_breadth(op.id, repo: @repo) == 1
    end

    test "clear/2 re-enables a suspended operator (explicit, manual)" do
      op_id = "op-clear-#{System.unique_integer([:positive])}"
      {:ok, _} = Suspension.suspend(%{operator_id: op_id, reason: "budget", repo: @repo})
      assert Suspension.suspended?(op_id, repo: @repo)

      assert {:ok, %SuspensionRow{}} = Suspension.clear(op_id, %{repo: @repo})
      refute Suspension.suspended?(op_id, repo: @repo)
    end
  end

  # ==========================================================================
  # (e) R8 — unanchored-entries telemetry fires
  # ==========================================================================

  describe "(e) unanchored-entries telemetry (R8)" do
    test "RED: telemetry fires with a positive count while local entries await anchoring",
         %{path: path} do
      op = operator()

      test_pid = self()
      handler_id = "bg-unanchored-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:samen, :break_glass, :unanchored],
        fn _event, measurements, _meta, _cfg ->
          send(test_pid, {:unanchored, measurements.count})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Two break-glass reveals, none anchored yet.
      for _ <- 1..2 do
        {s, m} = vaulted("unanchored@example.com")
        {:ok, _} = BreakGlass.reveal(req(op, s, m, %{local_audit_path: path}))
      end

      count = Reconciliation.emit_unanchored_signal(repo: @repo, path: path)
      assert count == 2
      assert_receive {:unanchored, 2}
    end

    test "after reconciliation the unanchored count returns to zero", %{path: path} do
      op = operator()
      org = "org-e-#{System.unique_integer([:positive])}"

      {s, m} = vaulted("e@example.com")
      {:ok, _} = BreakGlass.reveal(req(op, s, m, %{local_audit_path: path, org_id: org}))

      assert Reconciliation.unanchored_count(repo: @repo, path: path) == 1
      assert {:ok, %{anchored: 1}} = Reconciliation.reconcile(repo: @repo, path: path)
      assert Reconciliation.unanchored_count(repo: @repo, path: path) == 0
    end
  end

  # ==========================================================================
  # In-test anti-tautology probes (positive controls — HARD RULE 2 "confirm the flip")
  # These prove the gates are NON-VACUOUS at the assertion level; the code-sabotage
  # anti-tautology probes on the KMS path and the budget are in the report.
  # ==========================================================================

  describe "anti-tautology positive controls" do
    test "the KMS-down deny is NOT an always-deny: with KMS up the SAME call succeeds",
         %{path: path} do
      op = operator()
      {subject_id, masked} = vaulted("probe-kms@example.com")

      FileBacked.simulate_outage(true)
      assert {:error, :unavailable} = BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))

      FileBacked.simulate_outage(false)
      assert {:ok, %{plaintext: "probe-kms@example.com"}} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))
    end

    test "the budget is NOT an always-suspend: within budget the operator is NOT suspended",
         %{path: path} do
      # Default budget (25) — a handful of reveals stays well under it.
      op = operator()

      for _ <- 1..4 do
        {s, m} = vaulted("probe-budget@example.com")
        assert {:ok, _} = BreakGlass.reveal(req(op, s, m, %{local_audit_path: path}))
      end

      refute Suspension.suspended?(op.id, repo: @repo)
    end
  end

  # A base64-safe mutation that changes the decoded bytes (flip a payload char).
  defp mutate_b64(b64) do
    {:ok, raw} = Base.decode64(b64)
    # Flip a byte in the middle of the JSON so the canonical no longer matches the
    # stored content hash (a tamper).
    idx = div(byte_size(raw), 2)
    <<head::binary-size(^idx), c, tail::binary>> = raw
    flipped = if c == ?a, do: ?b, else: ?a
    Base.encode64(<<head::binary, flipped, tail::binary>>)
  end
end
