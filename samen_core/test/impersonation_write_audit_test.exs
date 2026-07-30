defmodule Samen.ImpersonationWriteAuditTest do
  @moduledoc """
  P7-F1 (security · ESCALATE) — the write-granularity audit for operator-under-
  impersonation mutations (ADR-040 §6.6; persona-7 finding P7-F1).

  The persona-7 dogfood walk drove a real `Samen.Impersonation` session, renamed a
  tenant `Load` through the ordinary authorized Ash update path, and found the
  mutation produced **no per-mutation audit row** — the `aud_event` delta was exactly
  the session `open` event, zero rows for the mutated subject, the only trace a bumped
  `updated_at`. Session-level attribution existed; write-level attribution did not.

  `Samen.Audit.ImpersonationWrite` (a global `Ash.Resource.Change` added to EVERY
  `use Samen.Resource` via `Samen.Transformers.ImpersonationAudit`) closes the gap: every
  mutation whose acting actor carries the `:impersonation` marker emits a token-only,
  in-transaction (fail-closed) `impersonation_write` `aud_event` naming the operator, the
  session id, the tenant subject, and the action — REGARDLESS of whether the target
  resource opted into `versioned true`/E7. The pilot here
  (`SamenCore.Support.Archivable.Widget`) has NOT opted into `versioned`, proving the
  impersonation chokepoint — not the resource's opt-in — is the enforcement point.

  Coverage (attempt 2): single-record writes (create/update/destroy/archive/restore/
  destroy_permanently) AND bulk_create / bulk_update, each in-transaction and fail-closed.

  House red-path discipline (CLAUDE.md "every red-path pairs denial with a positive
  control"): the RED cases prove the row is present for impersonated writes; the CONTROLs
  prove a normal tenant-member write of the SAME resource produces NO such row (so the
  mandatory-first-client rule is scoped to impersonation context only, not a blanket-audit
  regression of E7's opt-in default). The SABOTAGE TWIN
  (`scripts/sabotages/33-p7f1-impersonation-write-audit-drop.patch`) neutralizes the audit
  emission so the RED assertions fail — proving they are not tautologies.
  """
  use ExUnit.Case, async: false

  alias Samen.Impersonation
  alias Samen.OperatorPlane.Actor
  alias SamenCore.Support.Archivable.Widget

  @repo SamenCore.TestRepo

  setup do
    # Impersonation.open/3 runs an Ecto.Multi + same-tx Oban enqueue, so the sandbox
    # must be shared (mirrors impersonation_same_tx_test.exs).
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Ecto.Adapters.SQL.Sandbox.mode(@repo, {:shared, self()})
    :ok
  end

  defp uniq, do: System.unique_integer([:positive])
  defp operator, do: Actor.new("operator-#{uniq()}", :operator_support)

  # A NORMAL tenant-member scope (plane :tenant, NO impersonation marker).
  defp tenant_scope(org) do
    %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp new_widget(scope, org, name, code) do
    Widget
    |> Ash.Changeset.for_create(:create, %{org_id: org, name: name, code: code}, scope: scope)
    |> Ash.create!()
  end

  defp impersonation_write_rows(org) do
    @repo
    |> Samen.AuditEvent.for_subject(org)
    |> Enum.filter(&(&1.event_type == "impersonation_write"))
  end

  test "RED (P7-F1): an impersonated UPDATE emits an attributable impersonation_write aud_event" do
    org = Ecto.UUID.generate()
    op = operator()
    tenant = tenant_scope(org)

    # SETUP: a normal tenant-member create — NOT impersonated → produces no
    # impersonation_write row (the notifier is a no-op without the marker).
    widget = new_widget(tenant, org, "orig", "code-#{uniq()}")
    assert impersonation_write_rows(org) == []

    # Open a real impersonation session (writes the session `open` event on the org's
    # hash chain — event_type "impersonation", NOT "impersonation_write").
    {:ok, session} = Impersonation.open(op, org, "P7 ticket #123: rename load")
    {:ok, scope} = Impersonation.scope(op, org)
    assert Samen.Impersonation.Scope.impersonated?(scope)

    # Mutate the tenant record through the ORDINARY authorized Ash update path — the
    # exact P7-F1 scenario (a member-equivalent operator renaming a tenant record).
    widget
    |> Ash.Changeset.for_update(:update, %{name: "renamed [P7-PROBE]"}, scope: scope)
    |> Ash.update!()

    assert [row] = impersonation_write_rows(org),
           "an impersonated write MUST produce exactly one attributable audit row"

    # INV-2 two-plane attribution — the row names BOTH identities:
    assert row.actor_id == op.id, "operator identity"
    assert row.correlation_id == session.id, "impersonation session id"
    assert row.subject_id == org, "tenant subject (org)"
    # ...and the action + the mutated record identity (a token-only object-ref).
    assert row.detail =~ "action=update"
    assert row.detail =~ "samen:arv:#{widget.id}"

    # The four audit tiers stay disjoint (ADR-040 §7.4): the session `open` lands as
    # event_type "impersonation"; the write lands as the distinct "impersonation_write".
    all = Samen.AuditEvent.for_subject(@repo, org)
    assert Enum.any?(all, &(&1.event_type == "impersonation")),
           "the session open event is still recorded (session-level attribution)"
  end

  test "CONTROL: a normal (non-impersonation) tenant-member update emits NO impersonation_write row" do
    org = Ecto.UUID.generate()
    tenant = tenant_scope(org)
    widget = new_widget(tenant, org, "orig", "code-#{uniq()}")

    widget
    |> Ash.Changeset.for_update(:update, %{name: "edited by member"}, scope: tenant)
    |> Ash.update!()

    # The mandatory-first-client rule is scoped to impersonation context ONLY. Ordinary
    # tenant CRUD is NOT blanket-audited — E7 stays opt-in for non-impersonated writes,
    # so a silent always-audit regression would show up here.
    assert impersonation_write_rows(org) == []
  end

  test "RED (P7-F1): an impersonated CREATE is audited too (not just update)" do
    org = Ecto.UUID.generate()
    op = operator()
    {:ok, session} = Impersonation.open(op, org, "P7 ticket #124")
    {:ok, scope} = Impersonation.scope(op, org)

    created =
      Widget
      |> Ash.Changeset.for_create(:create, %{org_id: org, name: "n", code: "code-#{uniq()}"},
        scope: scope
      )
      |> Ash.create!()

    assert [row] = impersonation_write_rows(org)
    assert row.detail =~ "action=create"
    assert row.detail =~ "samen:arv:#{created.id}"
    assert row.actor_id == op.id
    assert row.correlation_id == session.id
  end

  test "INV-1: the impersonation_write audit row carries NO plaintext value and NO vt_ token" do
    org = Ecto.UUID.generate()
    op = operator()
    tenant = tenant_scope(org)

    # A PII-shaped sentinel as the mutated value. The audit row records only the
    # object-ref + action + identities — it must never persist the CHANGED VALUE, so a
    # store_action_inputs-style leak (or a version-diff leak) would surface the sentinel.
    sentinel = "sentinel-#{uniq()}@secret.example"
    widget = new_widget(tenant, org, "orig", "code-#{uniq()}")

    {:ok, _session} = Impersonation.open(op, org, "P7 ticket #125")
    {:ok, scope} = Impersonation.scope(op, org)

    widget
    |> Ash.Changeset.for_update(:update, %{name: sentinel}, scope: scope)
    |> Ash.update!()

    [row] = impersonation_write_rows(org)

    blob =
      [row.event_type, row.subject_id, row.actor_id, to_string(row.correlation_id), row.detail]
      |> Enum.map_join(" ", &to_string/1)

    refute blob =~ sentinel, "the audit row must not persist the mutated (PII-shaped) value"
    refute blob =~ "vt_", "the audit row must not carry a vault token"
  end

  # ── BULK coverage (attempt-2 gap 1): bulk paths must NOT escape the audit ──────

  test "RED (bulk): an impersonated bulk_create audits EVERY created row" do
    org = Ecto.UUID.generate()
    op = operator()
    {:ok, session} = Impersonation.open(op, org, "P7 ticket #126: bulk import")
    {:ok, scope} = Impersonation.scope(op, org)

    inputs =
      for i <- 1..3, do: %{org_id: org, name: "bulk-#{i}", code: "code-#{uniq()}"}

    result =
      Ash.bulk_create(inputs, Widget, :create,
        actor: scope.actor,
        return_records?: true,
        return_errors?: true
      )

    assert %Ash.BulkResult{status: :success, records: records} = result
    ids = Enum.map(records, & &1.id)

    rows = impersonation_write_rows(org)
    assert length(rows) == 3, "every bulk-created row must be audited (bulk must not escape)"
    assert Enum.all?(rows, &(&1.event_type == "impersonation_write"))
    assert Enum.all?(rows, &(&1.actor_id == op.id))
    assert Enum.all?(rows, &(&1.correlation_id == session.id))
    # Each affected record identity is attributed (a compliance officer can reconstruct
    # exactly which N tenant rows the operator bulk-changed).
    for id <- ids, do: assert(Enum.any?(rows, &(&1.detail =~ "samen:arv:#{id}")))
    assert Enum.all?(rows, &(&1.detail =~ "action=create"))
  end

  test "RED (bulk): an impersonated bulk_update audits EVERY affected row" do
    org = Ecto.UUID.generate()
    op = operator()
    tenant = tenant_scope(org)
    widgets = for i <- 1..3, do: new_widget(tenant, org, "orig-#{i}", "code-#{uniq()}")
    assert impersonation_write_rows(org) == []

    {:ok, session} = Impersonation.open(op, org, "P7 ticket #127: bulk rename")
    {:ok, scope} = Impersonation.scope(op, org)

    result =
      Ash.bulk_update(widgets, :update, %{name: "bulk-renamed"},
        actor: scope.actor,
        return_records?: true,
        return_errors?: true
      )

    assert %Ash.BulkResult{status: :success} = result

    rows = impersonation_write_rows(org)
    assert length(rows) == 3, "every bulk-updated row must be audited (bulk must not escape)"
    assert Enum.all?(rows, &(&1.correlation_id == session.id and &1.actor_id == op.id))

    for w <- widgets, do: assert(Enum.any?(rows, &(&1.detail =~ "samen:arv:#{w.id}")))
    assert Enum.all?(rows, &(&1.detail =~ "action=update"))
  end

  test "RED (destroy): an impersonated single-record :destroy AND :destroy_permanently each audit (in-transaction)" do
    # Destroys are the cascade-parent case: an impersonated destroy of a parent (which may
    # then archive/destroy children) is itself audited at write granularity. The change is
    # registered `on: [:create, :update, :destroy]`, so destroys audit IN-TRANSACTION and
    # FAIL-CLOSED (like create/update) — no post-commit best-effort path. Proven here for
    # both the soft :destroy (archival) and the terminal :destroy_permanently.
    org = Ecto.UUID.generate()
    op = operator()
    tenant = tenant_scope(org)
    w1 = new_widget(tenant, org, "a", "code-#{uniq()}")
    w2 = new_widget(tenant, org, "b", "code-#{uniq()}")

    {:ok, session} = Impersonation.open(op, org, "P7 ticket #128: destroy")
    {:ok, scope} = Impersonation.scope(op, org)

    w1 |> Ash.Changeset.for_destroy(:destroy, %{}, scope: scope) |> Ash.destroy!()
    w2 |> Ash.Changeset.for_destroy(:destroy_permanently, %{}, scope: scope) |> Ash.destroy!()

    rows = impersonation_write_rows(org)
    assert length(rows) == 2, "each impersonated single-record destroy is audited exactly once"
    assert Enum.all?(rows, &(&1.correlation_id == session.id and &1.actor_id == op.id))
    assert Enum.any?(rows, &(&1.detail =~ "samen:arv:#{w1.id}"))
    assert Enum.any?(rows, &(&1.detail =~ "samen:arv:#{w2.id}"))
  end

  test "ATOMICITY (fail-closed, destroy): if the audit write fails, the impersonated destroy ABORTS" do
    org = Ecto.UUID.generate()
    op = operator()
    tenant = tenant_scope(org)
    widget = new_widget(tenant, org, "keepme", "code-#{uniq()}")

    {:ok, _session} = Impersonation.open(op, org, "P7 ticket #128b: destroy fail-closed")
    {:ok, scope} = Impersonation.scope(op, org)

    Application.put_env(:samen_core, :impersonation_audit_fault, true)
    on_exit(fn -> Application.delete_env(:samen_core, :impersonation_audit_fault) end)

    # Destroy is now in-transaction: a failed audit MUST abort the destroy (record survives).
    assert {:error, _} =
             widget
             |> Ash.Changeset.for_destroy(:destroy_permanently, %{}, scope: scope)
             |> Ash.destroy()

    assert Ash.get!(Widget, widget.id, authorize?: false).id == widget.id,
           "the impersonated destroy must have rolled back (record still present)"

    assert impersonation_write_rows(org) == []
  end

  test "RED (bulk): an impersonated bulk_destroy audits EVERY destroyed row" do
    org = Ecto.UUID.generate()
    op = operator()
    tenant = tenant_scope(org)
    widgets = for i <- 1..3, do: new_widget(tenant, org, "w#{i}", "code-#{uniq()}")

    {:ok, session} = Impersonation.open(op, org, "P7 ticket #129: bulk destroy")
    {:ok, scope} = Impersonation.scope(op, org)

    require Ash.Query
    query = Widget |> Ash.Query.filter(org_id == ^org)

    result =
      Ash.bulk_destroy(query, :destroy_permanently, %{},
        scope: scope,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic, :atomic_batches, :stream]
      )

    assert %Ash.BulkResult{status: :success} = result

    rows = impersonation_write_rows(org)
    assert length(rows) == 3, "every bulk-destroyed row must be audited (bulk_destroy must not escape)"
    assert Enum.all?(rows, &(&1.correlation_id == session.id and &1.actor_id == op.id))
    for w <- widgets, do: assert(Enum.any?(rows, &(&1.detail =~ "samen:arv:#{w.id}")))
  end

  test "CONTROL (bulk_destroy): a normal (non-impersonation) bulk_destroy emits NO impersonation_write row" do
    org = Ecto.UUID.generate()
    tenant = tenant_scope(org)
    for i <- 1..3, do: new_widget(tenant, org, "w#{i}", "code-#{uniq()}")

    require Ash.Query
    query = Widget |> Ash.Query.filter(org_id == ^org)

    assert %Ash.BulkResult{status: :success} =
             Ash.bulk_destroy(query, :destroy_permanently, %{},
               scope: tenant,
               return_records?: true,
               return_errors?: true
             )

    assert impersonation_write_rows(org) == []
  end

  test "CONTROL (bulk): a normal (non-impersonation) bulk_update emits NO impersonation_write row" do
    org = Ecto.UUID.generate()
    tenant = tenant_scope(org)
    widgets = for i <- 1..3, do: new_widget(tenant, org, "orig-#{i}", "code-#{uniq()}")

    result =
      Ash.bulk_update(widgets, :update, %{name: "edited"},
        actor: tenant.actor,
        return_records?: true,
        return_errors?: true
      )

    assert %Ash.BulkResult{status: :success} = result
    # Non-impersonated bulk is NOT audited AND is not forced onto the return_records?
    # path by the audit hook (batch_callbacks? returns false without the marker).
    assert impersonation_write_rows(org) == []
  end

  # ── FAIL-CLOSED atomicity (attempt-2 gap 2) ───────────────────────────────────

  test "ATOMICITY (fail-closed): if the audit write fails, the impersonated write ABORTS (no orphan, no unaudited mutation)" do
    org = Ecto.UUID.generate()
    op = operator()
    tenant = tenant_scope(org)
    widget = new_widget(tenant, org, "orig", "code-#{uniq()}")

    {:ok, _session} = Impersonation.open(op, org, "P7 ticket #129: fail-closed")
    {:ok, scope} = Impersonation.scope(op, org)

    # Arm the audit fault seam: the in-transaction audit write now errors.
    Application.put_env(:samen_core, :impersonation_audit_fault, true)
    on_exit(fn -> Application.delete_env(:samen_core, :impersonation_audit_fault) end)

    result =
      widget
      |> Ash.Changeset.for_update(:update, %{name: "should-not-persist"}, scope: scope)
      |> Ash.update()

    # The write MUST fail (fail-closed) — it cannot commit without recording its audit.
    assert {:error, _} = result

    # No orphaned mutation: the record is byte-exact its pre-write value (rolled back).
    reloaded = Ash.get!(Widget, widget.id, authorize?: false)
    assert reloaded.name == "orig", "the impersonated mutation must have rolled back"

    # And no audit row was left behind.
    assert impersonation_write_rows(org) == []

    # POSITIVE CONTROL: with the fault cleared, the same impersonated write succeeds AND
    # audits — proving the abort above was the fail-closed gate, not a blanket refusal.
    Application.delete_env(:samen_core, :impersonation_audit_fault)

    assert {:ok, _} =
             widget
             |> Ash.Changeset.for_update(:update, %{name: "now-persists"}, scope: scope)
             |> Ash.update()

    assert Ash.get!(Widget, widget.id, authorize?: false).name == "now-persists"
    assert [_row] = impersonation_write_rows(org)
  end
end
