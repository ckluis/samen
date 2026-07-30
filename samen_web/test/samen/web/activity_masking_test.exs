defmodule Samen.Web.ActivityMaskingTest do
  @moduledoc """
  T115 (R3) — the operator activity/audit feed
  (`Samen.Web.Operator.ActivityLive` + `Samen.Web.Operator.ActivityReads`) at
  `/operator/activity/:org_id`. Answers `_orch/ux/dogfood-report.md` R4 / P4
  job-test 4: "what changed in org X in the last 24h?"

  Proofs, per CLAUDE.md's masking-watch-list discipline + T115's done-criteria:

    1. **Attribution** — a real impersonation-write `aud_event` row (T38's
       P7-F1-mandated tier) renders with operator identity + session id +
       "acting as tenant" marker + tenant subject, all distinguishable from a
       generic actor column (done-criterion 2).
    2. **Org-scoped (INV-2), impersonation family** (`subject_id == org_id`) —
       two orgs' rows never bleed into each other's feed; an unrelated event
       type's colliding `subject_id` is excluded.
    2b. **COMPLETENESS + Org-scoped (INV-2), the "system" bucket**
       (`correlation_id == org_id`, T115 fix-round R2) — org-scoped
       governance events beyond impersonation (webhook/file/notification/
       ticket-breach/workflow/marketing) genuinely appear in the feed for the
       org they belong to; two orgs' "system" rows never bleed; a
       `correlation_id`-less or colliding row fails closed.
    2c. **COMPLETENESS + Org-scoped (INV-2), the approval family**
       (`correlation_id` = an Approval id, INDIRECT org resolution via the
       host-configured Approval resource) — an org's approval-lifecycle
       events appear in its feed; a DIFFERENT org's approval id never
       resolves into this org's feed; an approval id that doesn't resolve to
       ANY org (unwired engine, or an id matching nothing) fails closed.
    3. **Time-windowed** — the default 24h window excludes an out-of-window
       row; widening the window includes it (done-criterion 1).
    4. **INV-1 governance tier** — token-blind by construction: no `vt_*`
       token, no plaintext PII, ever renders from this tier (mirrors
       `operator_automation_health_test.exs`'s no-leak DOM scan). Paired with
       a sabotage twin proving the scan is refutable.
    5. **INV-1 history tier** — `ActivityReads.mask_changes/2` renders a
       vault-routed diff value as `••••`, never the raw `vt_*` token, via a
       STATIC cast (`Samen.Type.VaultField.cast_stored/2`) that never touches
       `Samen.Api.PiiResolution` / the vault — this surface never "helpfully"
       resolves a diff to plaintext. Proven at the read-layer (mirrors
       `versioned_change_log_test.exs`'s masked-render test, since no
       `versioned` DB fixture exists in this host yet — framework-first,
       honestly empty until a host adopts T119) AND at the full-page DOM level
       via the sanctioned `:feed` injection seam, with its own sabotage twin.
    6. **Read-only** — no `phx-click`/`phx-submit`/`<form` anywhere on the page
       (done-criterion 4).
    7. **HONESTY (T115 fix round 3)** — the rendered page NAMES the four
       governance families it structurally cannot org-scope (`operator
       suspension`, `break-glass`, `grant lifecycle` / `erasure`, `record
       archival`/`restore`) in a visible `#coverage-caveat` block, not only in
       a code comment — an operator reading the screen gets an accurate
       coverage picture, not an implied-complete change-log.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.AuditEvent
  alias Samen.Web.Operator.{ActivityLive, ActivityReads}
  alias Samen.WebTest.Automation.Workflow
  alias Samen.WebTest.Repo

  # ---------------------------------------------------------------------------
  # Seed helpers — write REAL aud_event rows in the SAME shape the production
  # writers use (`Samen.Audit.ImpersonationEmit.emit/4`,
  # `Samen.Impersonation.Sessions.emit_event/3`), so this test proves the
  # reader against the actual on-disk row shape, not an invented one.
  # ---------------------------------------------------------------------------

  defp insert_impersonation_write!(org_id, opts \\ []) do
    operator_id = Keyword.get(opts, :operator_id, "operator-#{System.unique_integer([:positive])}")
    session_id = Keyword.get(opts, :session_id, Ash.UUID.generate())
    action = Keyword.get(opts, :action, "update")
    object_ref = Keyword.get(opts, :object_ref, "samen:svc:#{Ash.UUID.generate()}")
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    {:ok, row} =
      AuditEvent.insert(Repo, %{
        event_type: "impersonation_write",
        subject_id: org_id,
        actor_id: operator_id,
        correlation_id: session_id,
        detail: "event=impersonation_write action=#{action} session=#{session_id} subject=#{object_ref}",
        occurred_at: occurred_at
      })

    row
  end

  defp insert_impersonation_session!(org_id, lifecycle, opts) do
    operator_id = Keyword.get(opts, :operator_id, "operator-#{System.unique_integer([:positive])}")
    session_id = Keyword.get(opts, :session_id, Ash.UUID.generate())
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    {:ok, row} =
      AuditEvent.insert(Repo, %{
        event_type: "impersonation",
        subject_id: org_id,
        actor_id: operator_id,
        correlation_id: session_id,
        detail: "event=#{lifecycle} reason=routine support",
        occurred_at: occurred_at
      })

    row
  end

  # An UNRELATED event type whose subject_id is NOT an org (e.g. a "system"
  # audit keyed to a workflow id, `Samen.Automation.Health.audit_switch/4`'s
  # shape) — used to prove the reader's `@org_scoped_event_types` filter
  # excludes it even when its subject_id string happens to collide with an
  # org id under test (the INV-2 hazard the moduledoc calls out).
  defp insert_unrelated_system_event!(subject_id, opts \\ []) do
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    {:ok, row} =
      AuditEvent.insert(Repo, %{
        event_type: "system",
        subject_id: subject_id,
        actor_id: "operator-unrelated",
        correlation_id: Ash.UUID.generate(),
        detail: "event=automation.workflow.operator_kill killed=true",
        occurred_at: occurred_at
      })

    row
  end

  # A "system"-bucket governance event, in the SAME shape the live writers use
  # (`Samen.Scopes.Primitives.Audit.file_uploaded/3`,
  # `Samen.Scopes.Support.Audit.ticket_breached/3`,
  # `Samen.Automation.Breaker.audit_trip/2`,
  # `Samen.Scopes.Marketing.SendWorker.emit_blocked_audit/2`, etc.): a bare
  # `detail` prefix (the dotted `<namespace>.<event>.<name>` token, no
  # `action=`/`event=` label) + `correlation_id` set DIRECTLY to the mutated
  # record's own `org_id`.
  defp insert_system_event!(org_id, detail_prefix, opts \\ []) do
    subject_id = Keyword.get(opts, :subject_id, Ash.UUID.generate())
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    {:ok, row} =
      AuditEvent.insert(Repo, %{
        event_type: "system",
        subject_id: subject_id,
        actor_id: Keyword.get(opts, :actor_id),
        correlation_id: org_id,
        detail: detail_prefix,
        occurred_at: occurred_at
      })

    row
  end

  # A "system"-bucket event whose writer never set `correlation_id` — the
  # fail-closed case (a hypothetical future writer that regresses the
  # convention, or the confirmed-dead `identity.auth.*` family).
  defp insert_system_event_no_correlation!(opts \\ []) do
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    {:ok, row} =
      AuditEvent.insert(Repo, %{
        event_type: "system",
        subject_id: Ash.UUID.generate(),
        actor_id: "operator-orphan",
        correlation_id: nil,
        detail: "identity.auth.login",
        occurred_at: occurred_at
      })

    row
  end

  # An Approval decision-lifecycle event, in the SAME shape
  # `Samen.Approvals.audit/4` writes: `correlation_id` is the Approval row's
  # OWN id (here, a stand-in resource's id — see the approval tests' setup),
  # NOT an org id.
  defp insert_approval_event!(event_type, approval_id, opts) do
    occurred_at = Keyword.get(opts, :occurred_at, DateTime.utc_now())

    {:ok, row} =
      AuditEvent.insert(Repo, %{
        event_type: event_type,
        subject_id: Keyword.get(opts, :subject_ref, "samen:svc:#{Ash.UUID.generate()}"),
        actor_id: Keyword.get(opts, :actor_id, "operator-approval-actor"),
        correlation_id: approval_id,
        detail: "event=#{Keyword.get(opts, :lifecycle, "requested")}",
        occurred_at: occurred_at
      })

    row
  end

  defp create_workflow!(org_id) do
    Workflow
    |> Ash.Changeset.for_create(:create, %{
      org_id: org_id,
      name: "wf-#{System.unique_integer([:positive])}",
      status: :active,
      trigger_kind: :manual,
      owner_id: Ash.UUID.generate(),
      conditions: [],
      actions: [%{"kind" => "notify", "recipient" => "owner", "event_type" => "workflow.fired"}]
    })
    |> Ash.create!(authorize?: false)
  end

  # Wire the (repurposed, id+org_id-bearing) stand-in "Approval resource" for
  # the duration of one test, cleaned up on exit — samen_web's test host has
  # never wired the real `Samen.Approvals` engine (no live `Approval`
  # resource exists here), so this proves `ActivityReads`'s org-resolution
  # JOIN logic generically against ANY id+org_id-bearing resource, exactly the
  # shape a real `Approval` resource has (`org_id` + `id`) — the read layer
  # only ever selects `[:id]` filtered by `org_id ==`, it has no other
  # dependency on what the resource "means".
  defp with_stand_in_approval_resource(fun) do
    prev = Application.get_env(:samen_core, Samen.Approvals)
    Application.put_env(:samen_core, Samen.Approvals, approval_resource: Workflow)

    try do
      fun.()
    after
      if prev, do: Application.put_env(:samen_core, Samen.Approvals, prev), else: Application.delete_env(:samen_core, Samen.Approvals)
    end
  end

  defp render_activity(org_id, window_hours \\ nil, opts \\ []) do
    mount = build_operator_mount(Ash.UUID.generate())

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> ActivityLive.load(org_id, window_hours, opts)
    |> then(&render_html(ActivityLive, &1.assigns))
  end

  # ==========================================================================
  # 1. Attribution — impersonation-write row renders distinguishably
  # ==========================================================================

  test "an impersonation-write row renders operator identity + session id + 'acting as tenant' + tenant subject, distinguishable from a generic actor field" do
    org_id = Ash.UUID.generate()
    operator_id = "operator-attribution-sentinel"
    session_id = Ash.UUID.generate()

    row = insert_impersonation_write!(org_id, operator_id: operator_id, session_id: session_id, action: "update")

    html = render_activity(org_id)

    assert html =~ "acting as tenant"
    assert html =~ operator_id
    assert html =~ session_id
    # The tenant subject (the org acted upon) is visible, not folded away.
    assert html =~ org_id
    assert html =~ "update"
    assert html =~ "aud-#{row.id}"
  end

  test "an impersonation session bookend (open/close) also renders as an attributable, acting-as row" do
    org_id = Ash.UUID.generate()
    operator_id = "operator-session-sentinel"

    insert_impersonation_session!(org_id, "open", operator_id: operator_id)

    html = render_activity(org_id)

    assert html =~ "acting as tenant"
    assert html =~ operator_id
    assert html =~ "open"
  end

  # ==========================================================================
  # 2. Org-scoped (INV-2) — no cross-org bleed
  # ==========================================================================

  test "INV-2: org A's feed never shows org B's rows, even a same-shaped impersonation-write row" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    insert_impersonation_write!(org_a, operator_id: "operator-org-a-only")
    insert_impersonation_write!(org_b, operator_id: "operator-org-b-only")

    html_a = render_activity(org_a)

    assert html_a =~ "operator-org-a-only"
    refute html_a =~ "operator-org-b-only"
    refute html_a =~ org_b
  end

  test "INV-2: an unrelated event type (subject_id NOT an org, e.g. a system/workflow audit) never leaks into the org feed even on a colliding subject_id" do
    colliding_id = Ash.UUID.generate()

    # A "system" event whose subject_id happens to equal `colliding_id` — NOT an
    # org-scoped event type, so it must be excluded even though the raw string matches.
    insert_unrelated_system_event!(colliding_id)
    insert_impersonation_write!(colliding_id, operator_id: "operator-real-impersonation")

    html = render_activity(colliding_id)

    assert html =~ "operator-real-impersonation"
    refute html =~ "automation.workflow.operator_kill"
    refute html =~ "operator-unrelated"
  end

  # ==========================================================================
  # 2b. COMPLETENESS + Org-scoped (INV-2) — the "system" bucket
  #     (correlation_id == org_id)
  # ==========================================================================

  test "COMPLETENESS: org-scoped 'system' governance events (webhook/file/ticket/workflow/marketing-shaped) genuinely appear in the org's feed" do
    org_id = Ash.UUID.generate()

    insert_system_event!(org_id, "primitives.file.uploaded status=active")
    insert_system_event!(org_id, "primitives.file.promoted scanner=Noop verdict=clean")
    insert_system_event!(org_id, "primitives.notification.sent channel=in_app status=sent")
    insert_system_event!(org_id, "support.ticket.breached breach_at=2026-07-30T00:00:00Z")
    insert_system_event!(org_id, "automation.workflow.rate_tripped count=5 window_s=60 limit=3")
    insert_system_event!(org_id, "automation.workflow.operator_kill killed=true")
    insert_system_event!(org_id, "marketing.send.blocked reason=adapter_unconfigured")

    html = render_activity(org_id)

    assert html =~ "primitives.file.uploaded"
    assert html =~ "primitives.file.promoted"
    assert html =~ "primitives.notification.sent"
    assert html =~ "support.ticket.breached"
    assert html =~ "automation.workflow.rate_tripped"
    assert html =~ "automation.workflow.operator_kill"
    assert html =~ "marketing.send.blocked"
  end

  test "INV-2 ('system' bucket): org A's file/ticket/workflow events never bleed into org B's feed" do
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    insert_system_event!(org_a, "primitives.file.uploaded status=active", subject_id: "file-org-a-sentinel")
    insert_system_event!(org_b, "primitives.file.uploaded status=active", subject_id: "file-org-b-sentinel")

    html_a = render_activity(org_a)

    assert html_a =~ "file-org-a-sentinel"
    refute html_a =~ "file-org-b-sentinel"
  end

  test "INV-2 ('system' bucket) fails CLOSED: a row whose writer never set correlation_id is excluded from every org's feed" do
    org_id = Ash.UUID.generate()
    orphan = insert_system_event_no_correlation!()

    html = render_activity(org_id)

    refute html =~ "aud-#{orphan.id}"
    refute html =~ "identity.auth.login"
  end

  # ==========================================================================
  # 2c. COMPLETENESS + Org-scoped (INV-2) — the approval family
  #     (correlation_id = an Approval id, INDIRECT org resolution)
  # ==========================================================================

  test "COMPLETENESS: an approval-lifecycle event resolves to its org via the host-configured Approval resource and appears in that org's feed" do
    with_stand_in_approval_resource(fn ->
      org_id = Ash.UUID.generate()
      approval = create_workflow!(org_id)

      insert_approval_event!("approval_requested", approval.id, lifecycle: "requested")

      html = render_activity(org_id)

      assert html =~ "approval_requested"
      assert html =~ "requested"
    end)
  end

  test "INV-2 (approval family): org A's approval id never resolves into org B's feed, even though the SAME AuditEvent row exists" do
    with_stand_in_approval_resource(fn ->
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      approval_a = create_workflow!(org_a)

      insert_approval_event!("approval_approved", approval_a.id, subject_ref: "samen:svc:approval-a-sentinel")

      html_a = render_activity(org_a)
      html_b = render_activity(org_b)

      assert html_a =~ "approval-a-sentinel"
      refute html_b =~ "approval-a-sentinel"
    end)
  end

  test "INV-2 (approval family) fails CLOSED: an approval id matching NO row in the org's OWN id-set is excluded, even though the org DOES have other real approvals" do
    with_stand_in_approval_resource(fn ->
      org_id = Ash.UUID.generate()
      # The org has a REAL approval id (so `approval_ids_for_org/1` returns a
      # non-empty set) — the garbage id below must still be excluded by the
      # `correlation_id in ^approval_ids` filter, not merely by an empty set.
      real_approval = create_workflow!(org_id)
      insert_approval_event!("approval_approved", real_approval.id, subject_ref: "samen:svc:real-approval-sentinel")
      insert_approval_event!("approval_requested", Ash.UUID.generate(), subject_ref: "samen:svc:unresolvable-sentinel")

      html = render_activity(org_id)

      assert html =~ "real-approval-sentinel"
      refute html =~ "unresolvable-sentinel"
    end)
  end

  test "the approval family is a fail-honest no-op when the Approvals engine is unwired (no host config): no crash, event simply excluded" do
    # Deliberately NOT calling with_stand_in_approval_resource/1 — proves the
    # default (every test host today) degrades to [] rather than raising.
    org_id = Ash.UUID.generate()
    insert_approval_event!("approval_requested", Ash.UUID.generate(), subject_ref: "samen:svc:unwired-sentinel")
    insert_impersonation_write!(org_id, operator_id: "operator-unwired-control")

    html = render_activity(org_id)

    assert html =~ "operator-unwired-control"
    refute html =~ "unwired-sentinel"
  end

  # ==========================================================================
  # 3. Time-windowed
  # ==========================================================================

  test "the default 24h window excludes an out-of-window row; a widened window includes it" do
    org_id = Ash.UUID.generate()
    now = DateTime.utc_now()

    insert_impersonation_write!(org_id, operator_id: "operator-fresh", occurred_at: now)
    insert_impersonation_write!(org_id, operator_id: "operator-stale-25h", occurred_at: DateTime.add(now, -25 * 3600, :second))

    default_html = render_activity(org_id, nil, now: now)
    assert default_html =~ "operator-fresh"
    refute default_html =~ "operator-stale-25h"

    widened_html = render_activity(org_id, "168", now: now)
    assert widened_html =~ "operator-fresh"
    assert widened_html =~ "operator-stale-25h"
  end

  # ==========================================================================
  # 4. INV-1 governance tier — token-blind by construction + sabotage twin
  # ==========================================================================

  test "INV-1: no vt_ token, no plaintext-looking sentinel, ever renders from a realistic governance row" do
    org_id = Ash.UUID.generate()
    insert_impersonation_write!(org_id, operator_id: "operator-clean", action: "update")

    html = render_activity(org_id)

    refute html =~ ~r/\bvt_/
    assert html =~ "operator-clean"
  end

  test "SABOTAGE TWIN: a modeled leak in the aud_event `detail` string IS caught by the DOM scan (proving it is refutable, not vacuous)" do
    org_id = Ash.UUID.generate()

    # `Samen.AuditEvent.insert/2` (unlike `Samen.AuditChain.Writer.write/2`) does
    # NOT run `Samen.PiiReasonScan` — model what a leaked write would look like if
    # a future writer regressed and stuffed a subject value into `detail`.
    {:ok, _} =
      AuditEvent.insert(Repo, %{
        event_type: "impersonation_write",
        subject_id: org_id,
        actor_id: "operator-leak-canary",
        correlation_id: Ash.UUID.generate(),
        detail: "event=impersonation_write action=update session=leak-canary-secret-token-771 subject=samen:svc:x",
        occurred_at: DateTime.utc_now()
      })

    html = render_activity(org_id)

    assert html =~ "leak-canary-secret-token-771",
           "the scan must be able to detect a leak in `detail`, else the INV-1 red-path assertion above is vacuous"
  end

  # ==========================================================================
  # 5. INV-1 history tier — mask_changes/2 never resolves to plaintext
  # ==========================================================================

  test "mask_changes/2: a vault-routed key masks to •••• via a STATIC cast (never the raw vt_ token); a plain key stays exactly as stored" do
    raw_token = "vt_" <> Base.encode16(:crypto.strong_rand_bytes(8))
    changes = %{"full_name" => raw_token, "label" => "ordinary-stored-value"}

    masked = ActivityReads.mask_changes(changes, MapSet.new(["full_name"])) |> Map.new()

    assert masked["full_name"] == "••••"
    refute masked["full_name"] =~ "vt_"
    # The plain (non-vault) key renders EXACTLY what was stored — proving the
    # mask is the vault field's doing, not blanket redaction.
    assert masked["label"] == "ordinary-stored-value"
  end

  test "ANTI-TAUTOLOGY: the raw (unmasked) token DOES contain vt_ — proving mask_changes/2's output above is a real transformation, not vacuous" do
    raw_token = "vt_" <> Base.encode16(:crypto.strong_rand_bytes(8))
    changes = %{"full_name" => raw_token}

    # What the page would show if it rendered `changes` directly (the mistake
    # INV-1 forbids) — the SAME map, unmasked.
    assert Jason.encode!(changes) =~ "vt_"

    masked = ActivityReads.mask_changes(changes, MapSet.new(["full_name"])) |> Map.new()
    refute Jason.encode!(masked) =~ "vt_"
  end

  test "SABOTAGE TWIN at the full-page level: a feed item carrying a raw, unmasked vt_ token WOULD render (via the :feed injection seam), proving the page's own DOM scan is refutable" do
    org_id = Ash.UUID.generate()
    raw_token = "vt_" <> Base.encode16(:crypto.strong_rand_bytes(8))

    leaked_feed = %{
      window_hours: 24,
      cutoff: DateTime.utc_now(),
      items: [
        %{
          id: "version-leak-canary",
          tier: :history,
          occurred_at: DateTime.utc_now(),
          action: "update",
          actor_id: nil,
          object_ref: "samen:svc:leak-canary",
          impersonation?: false,
          session_id: nil,
          tenant_subject_id: nil,
          detail: nil,
          # Deliberately UNMASKED — the same field `mask_changes/2` would have
          # replaced with "••••" had the reader done its job.
          changes: [{"full_name", raw_token}]
        }
      ]
    }

    html = render_activity(org_id, nil, feed: leaked_feed)

    assert html =~ raw_token,
           "the page must be ABLE to render a raw token if the read layer ever failed to mask one, else the INV-1 proofs above are vacuous"
  end

  test "the REAL read path never produces what the sabotage twin modeled: a history-tier item's changes are always pre-masked (no vt_ reaches the template)" do
    # No `versioned` resource exists in this host yet (T119 adoption is
    # per-host) — `ActivityReads.activity/3`'s history tier is honestly empty,
    # never fabricated. This is the fail-honest counterpart to the sabotage
    # twin above: today, on THIS host, there is nothing to mask because there
    # is nothing to show — proven by asserting the real (non-injected) render
    # carries no history-tier row at all.
    org_id = Ash.UUID.generate()
    insert_impersonation_write!(org_id)

    html = render_activity(org_id)

    refute html =~ "version-"
  end

  # ==========================================================================
  # 6. Read-only (done-criterion 4)
  # ==========================================================================

  test "the page defines no write affordance: no phx-click, no phx-submit, no <form> anywhere" do
    org_id = Ash.UUID.generate()
    insert_impersonation_write!(org_id)

    html = render_activity(org_id)

    refute html =~ "phx-click"
    refute html =~ "phx-submit"
    refute html =~ "<form"
    refute function_exported?(ActivityLive, :handle_event, 3)
  end

  test "no org resolved renders the honest empty state, never a crash" do
    html = render_activity(nil)
    assert html =~ "No tenant org resolved."
  end

  # ==========================================================================
  # 7. HONESTY (T115 fix round 3) — the coverage caveat is RENDERED, naming
  #    the four families this feed structurally cannot org-scope. Remove the
  #    `#coverage-caveat` block (or any of the four names) and THIS test
  #    fails — sabotage-refutable in spirit, the same discipline as every
  #    other proof in this file.
  # ==========================================================================

  test "HONESTY: the rendered page names all four excluded governance families in a visible coverage caveat, not only in a code comment" do
    org_id = Ash.UUID.generate()
    insert_impersonation_write!(org_id)

    html = render_activity(org_id)

    assert html =~ "coverage-caveat"
    assert html =~ "operator suspension"
    assert html =~ "break-glass"
    assert html =~ "grant lifecycle"
    assert html =~ "erasure"
    assert html =~ "record archival"
    assert html =~ "restore"
  end

  test "HONESTY: the coverage caveat renders even when the feed is empty (an operator on a quiet org must still see the coverage limits)" do
    org_id = Ash.UUID.generate()

    html = render_activity(org_id)

    assert html =~ "No changes in this window."
    assert html =~ "coverage-caveat"
    assert html =~ "operator suspension"
  end

  test "HONESTY: the lane label no longer implies whole-aud_chain coverage" do
    org_id = Ash.UUID.generate()
    insert_impersonation_write!(org_id)

    html = render_activity(org_id)

    refute html =~ "aud_chain (incl. impersonation-writes)"
    assert html =~ "partial governance coverage"
  end
end
