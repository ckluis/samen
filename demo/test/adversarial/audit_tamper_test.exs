defmodule Demo.Adversarial.AuditTamperTest do
  @moduledoc """
  T4.6 — ADVERSARIAL suite, category 4: AUDIT TAMPER (edit / delete / rewrite) vs the
  hash chain + the out-of-band WORM anchor.

  Consolidated Phase-4 attack surface (plan §6.3 "audit tamper" + doc §control
  "Immutable and crypto-shreddable"), driven against the REAL `Samen.AuditChain` on
  `Demo.Repo` with the faithful `Samen.Anchor.LocalWorm` anchor. The tenant-readable
  audit is APPEND-ONLY, tamper-EVIDENT, and operator-UNEDITABLE. The attacks:

    (1) EDIT — an out-of-band UPDATE to a chained row's payload is detected by
        `verify_chain` (`:hash_mismatch`); the stored hash no longer matches the
        recomputed hash over the edited payload.
    (2) DELETE — an out-of-band DELETE of a middle row produces a `:seq_gap`.
    (3) APPEND-ONLY — an ordinary UPDATE/DELETE (attacker WITHOUT DDL rights) raises
        the append-only trigger — the operator cannot edit at all.
    (4) REWRITE-vs-ANCHOR — a WHOLESALE rebuilt chain that internally `verify_chain`s
        CLEAN is STILL caught by the WORM anchor (`verify_against_anchor` →
        `:anchor_divergence`). This is the load-bearing "operator cannot edit" claim:
        even a rebuild-from-scratch cannot forge the sealed head.
    (5) TRUNCATE-below-anchor — rolling the chain back below the sealed seq is detected
        (`:truncated_below_anchor`).
    (6) TENANT VIEW — the tenant-readable view surfaces `chain_verified: false` on a
        tampered chain (the tenant sees the tamper), and never leaks another org.

  POSITIVE CONTROL: the untampered chain verifies AND `verify_against_anchor` returns
  `:verified` — so every tamper detection is non-vacuous.

  Tag: `@moduletag :adversarial`.
  """
  use Demo.DataCase, async: false

  @moduletag :adversarial

  import Ecto.Query

  alias Samen.AuditChain
  alias Samen.AuditChain.{Entry, TenantView}
  alias Samen.Anchor.LocalWorm

  @repo Demo.Repo

  setup do
    # Fresh per-test WORM anchor file so seals don't leak between tests.
    path =
      Path.join(System.tmp_dir!(), "demo_adv_anchor_#{System.unique_integer([:positive])}.worm")

    prev_path = Application.get_env(:samen_core, :anchor_local_worm_path)
    prev_adapter = Application.get_env(:samen_core, :anchor_adapter)
    Application.put_env(:samen_core, :anchor_local_worm_path, path)
    Application.put_env(:samen_core, :anchor_adapter, LocalWorm)

    on_exit(fn ->
      File.rm(path)
      if prev_path,
        do: Application.put_env(:samen_core, :anchor_local_worm_path, prev_path),
        else: Application.delete_env(:samen_core, :anchor_local_worm_path)

      if prev_adapter,
        do: Application.put_env(:samen_core, :anchor_adapter, prev_adapter),
        else: Application.delete_env(:samen_core, :anchor_adapter)
    end)

    {:ok, org: "org-#{System.unique_integer([:positive])}"}
  end

  defp append!(org, attrs \\ %{}) do
    base = %{
      org_id: org,
      event_type: "reveal",
      subject_id: "subj-#{System.unique_integer([:positive])}",
      actor_id: "op-1",
      detail: "event=granted"
    }

    {:ok, %Entry{} = e} = AuditChain.append(Map.merge(base, attrs), repo: @repo)
    e
  end

  defp disable_trigger, do: @repo.query!("ALTER TABLE aud_chain DISABLE TRIGGER aud_chain_append_only_tg")
  defp enable_trigger, do: @repo.query!("ALTER TABLE aud_chain ENABLE TRIGGER aud_chain_append_only_tg")

  # ==========================================================================
  # POSITIVE CONTROL — untampered chain verifies + anchors verified
  # ==========================================================================

  test "POSITIVE CONTROL: an untampered chain verifies and matches its sealed anchor", %{org: org} do
    append!(org)
    append!(org)
    assert {:ok, %{entries: 2}} = AuditChain.verify_chain(org, repo: @repo)
    assert {:ok, %{seq: 1}} = AuditChain.seal(org)
    assert {:ok, :verified} = AuditChain.verify_against_anchor(org)
  end

  # ==========================================================================
  # (1) EDIT — payload tamper detected
  # ==========================================================================

  test "RED (edit): an out-of-band UPDATE to a chained row's payload breaks verify_chain", %{org: org} do
    _e0 = append!(org)
    e1 = append!(org)
    _e2 = append!(org)

    disable_trigger()
    @repo.query!("UPDATE aud_chain SET ach_detail = 'TAMPERED' WHERE ach_id = $1", [Ecto.UUID.dump!(e1.id)])
    enable_trigger()

    assert {:error, {:hash_mismatch, 1}} = AuditChain.verify_chain(org, repo: @repo)
  end

  # ==========================================================================
  # (2) DELETE — seq gap detected
  # ==========================================================================

  test "RED (delete): deleting a middle row produces a seq gap", %{org: org} do
    _e0 = append!(org)
    e1 = append!(org)
    _e2 = append!(org)

    disable_trigger()
    @repo.query!("DELETE FROM aud_chain WHERE ach_id = $1", [Ecto.UUID.dump!(e1.id)])
    enable_trigger()

    assert {:error, {:seq_gap, 1}} = AuditChain.verify_chain(org, repo: @repo)
  end

  # ==========================================================================
  # (3) APPEND-ONLY — ordinary UPDATE/DELETE raises (operator can't edit)
  # ==========================================================================

  test "RED (append-only): an ordinary UPDATE/DELETE raises the append-only trigger", %{org: org} do
    e0 = append!(org)

    assert_raise Postgrex.Error, ~r/append-only/i, fn ->
      @repo.query!("UPDATE aud_chain SET ach_detail = 'x' WHERE ach_id = $1", [Ecto.UUID.dump!(e0.id)])
    end

    assert_raise Postgrex.Error, ~r/append-only/i, fn ->
      @repo.query!("DELETE FROM aud_chain WHERE ach_id = $1", [Ecto.UUID.dump!(e0.id)])
    end
  end

  # ==========================================================================
  # (4) REWRITE-vs-ANCHOR — a wholesale rebuild is caught by the WORM anchor
  # ==========================================================================

  test "RED (rewrite): a rebuilt-from-scratch chain that internally verifies is caught by the anchor", %{org: org} do
    _e0 = append!(org, %{detail: "event=granted real"})
    _e1 = append!(org, %{detail: "event=expired real"})
    assert {:ok, %{seq: 1, hash: sealed_hash}} = AuditChain.seal(org)

    # Attacker drops the org's chain and rebuilds a doctored history from scratch —
    # internally consistent (fresh genesis, correct links).
    disable_trigger()
    @repo.query!("DELETE FROM aud_chain WHERE ach_org_id = $1", [org])
    enable_trigger()

    _f0 = append!(org, %{detail: "event=granted FABRICATED"})
    _f1 = append!(org, %{detail: "event=DENIED cover-up"})

    # The rebuilt chain verify_chains CLEAN (verify_chain alone can't catch a rewrite).
    assert {:ok, %{entries: 2}} = AuditChain.verify_chain(org, repo: @repo)

    # But the WORM anchor remembers the ORIGINAL sealed head → divergence detected.
    assert {:error, :anchor_divergence} = AuditChain.verify_against_anchor(org)

    rebuilt_head = @repo.one(from(e in Entry, where: e.org_id == ^org and e.seq == 1, select: e.hash))
    refute rebuilt_head == sealed_hash
  end

  # ==========================================================================
  # (5) TRUNCATE-below-anchor — detected
  # ==========================================================================

  test "RED (truncate): rolling the chain back below the sealed seq is detected", %{org: org} do
    _e0 = append!(org)
    _e1 = append!(org)
    _e2 = append!(org)
    assert {:ok, %{seq: 2}} = AuditChain.seal(org)

    disable_trigger()
    @repo.query!("DELETE FROM aud_chain WHERE ach_org_id = $1 AND ach_seq > 0", [org])
    enable_trigger()

    assert {:error, :truncated_below_anchor} = AuditChain.verify_against_anchor(org)
  end

  # ==========================================================================
  # (6) TENANT VIEW — surfaces chain_verified: false; no cross-org leak
  # ==========================================================================

  test "the tenant-readable view surfaces chain_verified: false on a tampered chain", %{org: org} do
    e0 = append!(org, %{detail: "event=granted"})
    append!(org, %{detail: "event=expired"})

    # POSITIVE CONTROL: the untampered view is verified.
    assert {:ok, %{chain_verified: true, chain_error: nil}} = TenantView.for_org(org, repo: @repo)

    disable_trigger()
    @repo.query!("UPDATE aud_chain SET ach_detail = 'X' WHERE ach_id = $1", [Ecto.UUID.dump!(e0.id)])
    enable_trigger()

    assert {:ok, view} = TenantView.for_org(org, repo: @repo)
    assert view.chain_verified == false
    assert {:hash_mismatch, 0} = view.chain_error
  end

  test "the tenant-readable view does NOT leak another org's entries", %{org: org} do
    other = "org-#{System.unique_integer([:positive])}"
    append!(org)
    append!(other)
    append!(other)

    assert {:ok, view} = TenantView.for_org(org, repo: @repo)
    assert length(view.entries) == 1
  end
end
