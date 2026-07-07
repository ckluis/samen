defmodule Demo.Adversarial.BreakGlassAbuseTest do
  @moduledoc """
  T4.6 — ADVERSARIAL suite, category 5: BREAK-GLASS ABUSE.

  Consolidated Phase-4 attack surface (plan §6.3 break-glass + doc "honest edges"
  break-glass bullet), driven against the REAL `Samen.BreakGlass` path on `Demo.Repo`
  with the `Samen.Kms.FileBacked` adapter (the only one that can `simulate_outage/1`).
  A vaulted secret is stored for a REAL demo subject and revealed under emergency.

  The attacks:

    (1) BUDGET BREACH — exceeding the per-operator breadth budget (N distinct subjects
        per window) DENIES the tripping reveal AND auto-suspends the operator; every
        subsequent reveal path (break-glass, routine, impersonation-open) then denies.
        REPEAT reveals of the SAME subject do NOT widen breadth (breadth, not depth).
    (2) KMS-DOWN BYPASS ATTEMPT — with the local audit sink fully writable, an operator
        tries to break glass while the KMS is down. It FAILS CLOSED (`:unavailable`) —
        there is NO degraded path that manufactures plaintext without the KMS. When the
        KMS heals, the SAME call succeeds (deny-RECOVERABLE, not a shred).
    (3) LOCAL-ENTRY TAMPER — after break-glass writes local entries, an attacker edits
        the on-disk hash-chained record. Reconciliation VERIFIES the local chain FIRST
        and refuses to anchor a tampered/gapped file (`{:local_tamper, _}`) — nothing
        reaches the central chain across the local→central seam.
    (4) NO-REASON / NON-ROLE — break-glass with no who/what/why refuses; a non-break-
        glass actor cannot break glass at all.

  POSITIVE CONTROL: a legitimate break-glass (reason + role + KMS up + writable audit)
  SUCCEEDS and lands a durable local entry — so every denial is non-vacuous.

  Tag: `@moduletag :adversarial`.
  """
  use Demo.DataCase, async: false

  @moduletag :adversarial

  import Ecto.Query

  alias Samen.BreakGlass
  alias Samen.BreakGlass.{LocalAudit, Budget, Reconciliation, AnchorRow}
  alias Samen.OperatorPlane.{Actor, Suspension, SuspensionRow}
  alias Samen.Kms.FileBacked
  alias Samen.{Vault, Masked}

  @repo Demo.Repo

  setup do
    FileBacked.simulate_outage(false)
    prior_kms = Application.get_env(:samen_core, :kms_adapter)
    Application.put_env(:samen_core, :kms_adapter, FileBacked)

    path = Path.join(System.tmp_dir!(), "demo_bg_#{System.unique_integer([:positive])}.local")
    File.rm_rf!(path)

    on_exit(fn ->
      FileBacked.simulate_outage(false)
      Application.put_env(:samen_core, :kms_adapter, prior_kms || FileBacked)
      File.rm_rf!(path)
    end)

    {:ok, path: path}
  end

  defp operator, do: Actor.new("op-#{System.unique_integer([:positive])}", :operator_break_glass)

  # Vault a secret for a fresh subject; return {subject_id, %Masked{}}.
  defp vaulted(secret) do
    subject_id = "subj-#{System.unique_integer([:positive])}"
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
        action: :reveal_contact,
        resource: Demo.Crm.Contact,
        org_id: "org-#{System.unique_integer([:positive])}",
        repo: @repo
      },
      overrides
    )
  end

  # ==========================================================================
  # POSITIVE CONTROL — a legitimate break-glass succeeds (non-vacuity anchor)
  # ==========================================================================

  test "POSITIVE CONTROL: reason + break-glass role + KMS up + writable audit → reveal SUCCEEDS", %{path: path} do
    op = operator()
    {subject_id, masked} = vaulted("alice@bg.test")

    assert {:ok, %{plaintext: "alice@bg.test", local_entry: entry}} =
             BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))

    # The who/what/why is durable locally BEFORE the reveal.
    assert entry.seq == 0
    assert entry.subject_id == subject_id
    assert entry.actor_id == op.id
    assert entry.reason =~ "INC-42"
    assert File.exists?(path)
    assert {:ok, %{count: 1}} = LocalAudit.verify_chain(path: path)
  end

  # ==========================================================================
  # (1) BUDGET BREACH — auto-suspend, all paths deny; breadth not depth
  # ==========================================================================

  describe "(1) breadth budget" do
    setup do
      prior = Application.get_env(:samen_core, :break_glass_breadth_budget)
      Application.put_env(:samen_core, :break_glass_breadth_budget, 3)
      on_exit(fn -> Application.put_env(:samen_core, :break_glass_breadth_budget, prior) end)
      :ok
    end

    test "RED: exceeding N distinct subjects DENIES and auto-suspends; every path then denies", %{path: path} do
      op = operator()

      # Budget = 3 distinct subjects. 1..3 succeed (positive control).
      for _ <- 1..3 do
        {s, m} = vaulted("budget@bg.test")
        assert {:ok, %{plaintext: "budget@bg.test"}} =
                 BreakGlass.reveal(req(op, s, m, %{local_audit_path: path}))
      end

      refute Suspension.suspended?(op.id, repo: @repo)

      # The 4th DISTINCT subject trips the budget → deny + auto-suspend.
      {s4, m4} = vaulted("budget@bg.test")
      assert {:error, :budget_exceeded} = BreakGlass.reveal(req(op, s4, m4, %{local_audit_path: path}))
      assert Suspension.suspended?(op.id, repo: @repo)

      # A suspension row exists (auditable).
      assert @repo.exists?(from(s in SuspensionRow, where: s.operator_id == ^op.id and is_nil(s.cleared_at)))

      # Every subsequent break-glass now denies with :operator_suspended (not budget).
      {s5, m5} = vaulted("budget@bg.test")
      assert {:error, :operator_suspended} = BreakGlass.reveal(req(op, s5, m5, %{local_audit_path: path}))

      # The suspension flag denies on the routine reveal path too.
      ctx = %Samen.Reveal.Context{
        actor: op.id,
        subject_id: "s",
        resource: Demo.Crm.Contact,
        action: :reveal_contact
      }

      refute Samen.Reveal.Grants.granted?(ctx)

      # And a suspended operator cannot open an impersonation session.
      assert {:error, :operator_suspended} =
               Samen.Impersonation.Sessions.open(%{
                 operator_id: op.id,
                 org_id: Ecto.UUID.generate(),
                 reason: "support",
                 repo: @repo
               })
    end

    test "repeat reveals of the SAME subject do NOT widen breadth (breadth, not depth)", %{path: path} do
      op = operator()
      {s, m} = vaulted("same@bg.test")

      for _ <- 1..5 do
        assert {:ok, _} = BreakGlass.reveal(req(op, s, m, %{local_audit_path: path}))
      end

      refute Suspension.suspended?(op.id, repo: @repo)
      assert Budget.current_breadth(op.id, repo: @repo) == 1
    end
  end

  # ==========================================================================
  # (2) KMS-DOWN BYPASS ATTEMPT — fails closed, deny-recoverable
  # ==========================================================================

  describe "(2) KMS-down bypass attempt" do
    test "RED: KMS down → break-glass FAILS CLOSED even with the local audit fully writable", %{path: path} do
      op = operator()
      {subject_id, masked} = vaulted("nobypass@bg.test")

      # Local audit sink is up; ONLY the KMS is down. No plaintext is manufactured.
      FileBacked.simulate_outage(true)
      assert {:error, :unavailable} = BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))

      # POSITIVE CONTROL: KMS heals → the SAME call succeeds (deny-RECOVERABLE, not shred).
      FileBacked.simulate_outage(false)
      assert {:ok, %{plaintext: "nobypass@bg.test"}} =
               BreakGlass.reveal(req(op, subject_id, masked, %{local_audit_path: path}))
    end
  end

  # ==========================================================================
  # (3) LOCAL-ENTRY TAMPER — reconciliation refuses to anchor a tampered file
  # ==========================================================================

  describe "(3) local-entry tamper" do
    test "control-plane returns → clean local entries anchor into aud_chain + aud_event", %{path: path} do
      op = operator()
      org = "org-recon-#{System.unique_integer([:positive])}"

      for _ <- 1..3 do
        {s, m} = vaulted("recon@bg.test")
        {:ok, _} = BreakGlass.reveal(req(op, s, m, %{local_audit_path: path, org_id: org}))
      end

      assert LocalAudit.count(path: path) == 3
      assert @repo.one(from(a in AnchorRow, select: count(a.id))) == 0

      assert {:ok, %{anchored: 3, already: 0, total: 3}} =
               Reconciliation.reconcile(repo: @repo, path: path)

      {:ok, chain} = Samen.AuditChain.verify_chain(org, repo: @repo)
      assert chain.entries >= 3
    end

    test "RED: a tampered local entry is detected at reconciliation and NOTHING is anchored", %{path: path} do
      op = operator()
      {s1, m1} = vaulted("t1@bg.test")
      {s2, m2} = vaulted("t2@bg.test")

      {:ok, _} = BreakGlass.reveal(req(op, s1, m1, %{local_audit_path: path}))
      {:ok, _} = BreakGlass.reveal(req(op, s2, m2, %{local_audit_path: path}))

      # Hand-edit the SECOND line's payload bytes (keep its stored hash).
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
        {s, m} = vaulted("gap@bg.test")
        {:ok, _} = BreakGlass.reveal(req(op, s, m, %{local_audit_path: path}))
      end

      [l0, _l1, l2] = File.read!(path) |> String.split("\n", trim: true)
      File.write!(path, l0 <> "\n" <> l2 <> "\n")

      assert {:error, {:local_tamper, {reason, _}}} = Reconciliation.reconcile(repo: @repo, path: path)
      assert reason in [:seq_gap, :broken_link]
      assert @repo.one(from(a in AnchorRow, select: count(a.id))) == 0
    end
  end

  # ==========================================================================
  # (4) NO-REASON / NON-ROLE — fail closed
  # ==========================================================================

  describe "(4) reason + role gates" do
    test "RED: break-glass with NO reason refuses (can't log who/what/why ⇒ no reveal)", %{path: path} do
      op = operator()
      {subject_id, masked} = vaulted("noreason@bg.test")

      assert {:error, :reason_required} =
               BreakGlass.reveal(req(op, subject_id, masked, %{reason: "", local_audit_path: path}))

      refute File.exists?(path)
    end

    test "RED: a non-break-glass actor cannot break glass", %{path: path} do
      {subject_id, masked} = vaulted("nonrole@bg.test")

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
  end

  # A base64-safe mutation that changes the decoded bytes (flip a payload char).
  defp mutate_b64(b64) do
    {:ok, raw} = Base.decode64(b64)
    idx = div(byte_size(raw), 2)
    <<head::binary-size(^idx), c, tail::binary>> = raw
    flipped = if c == ?a, do: ?b, else: ?a
    Base.encode64(<<head::binary, flipped, tail::binary>>)
  end
end
