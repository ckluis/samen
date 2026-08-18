defmodule SamenCore.TestRepo.Migrations.ApprovalsFixture do
  @moduledoc """
  T34 E3 approve/reject engine fixture tables (ADR-040 §4): the `Approval` state machine
  (`apv`) + a `Document` Gate-client (`apd`), mounted in `samen_core` tests via
  `test/support/approvals_fixture.ex`. TestRepo ONLY — the per-host primitives
  materialization (demo/driftwood/pawchart + gen goldens) is T35's sweep (§4.7).

  Load-bearing:

    * `apv_approval` — the decision record. `apv_org_id` is **nullable** (the documented
      Identity.Org exception, §4.1): non-NULL = tenant-plane, NULL = plane-global governance
      (reveal). The `apv_distinct_party` CHECK (`apv_decided_by IS NULL OR apv_decided_by <>
      apv_requested_by`) is the `rvg_distinct_party` twin — self-decision is impossible at
      the DB layer independent of the policy layer, and it applies to NULL-org rows too (it
      keys on the parties, never the org). Two partial unique indexes make a re-request
      idempotent while pending (one for tenant rows, one for NULL-org rows).
    * `apd_document` — a governed reference client with a 🔒 vault field
      (`pii_apd_secret`, allow-listed in `config/test.exs` since the fixture domain is not
      in `:ash_domains`). No approval row ever stores its secret (INV-1, §4.4).
  """
  use Samen.Migration

  @resources [
    SamenCore.Support.ApprovalsFixture.Approval,
    SamenCore.Support.ApprovalsFixture.Document
  ]

  def up do
    # --- apv_approval : the E3 decision record (state machine) ---
    create table(:apv_approval, primary_key: false) do
      # NULL = plane-global governance approval (reveal); non-NULL = tenant-plane (§4.1).
      add(:apv_org_id, :uuid)
      add(:apv_kind, :text, null: false)
      add(:apv_subject_ref, :text, null: false)
      add(:apv_requested_by, :text, null: false)
      add(:apv_decided_by, :text)
      add(:apv_reason, :text)
      add(:apv_deadline_at, :utc_datetime_usec)
      add(:apv_requested_at, :utc_datetime_usec)
      add(:apv_decided_at, :utc_datetime_usec)
      # AshStateMachine state (abbrev-prefixed via the pre-declared attribute, §5.8 C2).
      add(:apv_state, :text, null: false, default: "pending")
      add(:apv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:apv_inserted_at, :utc_datetime, null: false)
      add(:apv_updated_at, :utc_datetime, null: false)
    end

    # Distinct-party DB CHECK — the rvg_distinct_party twin (§4.2 layer 2), TIGHTENED to
    # also close the null-approver hole (T34-F1):
    #   (a) distinct-party in EVERY state — a non-NULL approver must differ from the
    #       requester (self-approval impossible at the DB, even a raw insert/update);
    #   (b) a DECIDED row (approved | rejected) MUST carry a non-NULL approver — so a raw
    #       insert of an 'approved'/'rejected' row with NULL apv_decided_by RAISES (a NULL
    #       approver can no longer satisfy the old `IS NULL OR` branch for a decided row).
    # pending/cancelled/expired rows legitimately have NULL apv_decided_by and are unaffected.
    # NULL-ORG exception PRESERVED: the check never references apv_org_id — a NULL-org
    # operator/reveal approval with a distinct non-NULL approver still satisfies it. NULL org
    # (a legit plane exception) and NULL approver (now refused on a decided row) are distinct.
    create(
      constraint(:apv_approval, :apv_distinct_party,
        check: """
        (apv_decided_by IS NULL OR apv_decided_by <> apv_requested_by)
        AND (apv_state NOT IN ('approved', 'rejected') OR apv_decided_by IS NOT NULL)
        """
      )
    )

    # Pending-uniqueness (§4.1): a re-request returns the existing pending approval rather
    # than a duplicate. Tenant rows key on {org_id, kind, subject_ref}; NULL-org rows on
    # {kind, subject_ref} via a second partial index (Postgres treats NULLs as distinct in
    # a plain unique index, so the org-scoped index alone would not dedup NULL-org rows).
    create(
      unique_index(:apv_approval, [:apv_org_id, :apv_kind, :apv_subject_ref],
        where: "apv_state = 'pending' AND apv_org_id IS NOT NULL",
        name: "apv_approval_pending_tenant_idx"
      )
    )

    create(
      unique_index(:apv_approval, [:apv_kind, :apv_subject_ref],
        where: "apv_state = 'pending' AND apv_org_id IS NULL",
        name: "apv_approval_pending_global_idx"
      )
    )

    create(index(:apv_approval, [:apv_org_id], name: "apv_approval_org_idx"))
    create(index(:apv_approval, [:apv_state, :apv_deadline_at], name: "apv_approval_expiry_idx"))

    # --- apd_document : the Gate reference client (carries a 🔒 vault field) ---
    create table(:apd_document, primary_key: false) do
      add(:apd_title, :text, null: false)
      add(:apd_status, :text, default: "draft")
      add(:apd_published_by, :uuid)
      add(:apd_locked_by, :uuid)
      add(:apd_note, :text)
      add(:pii_apd_secret, :text)
      add(:apd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:apd_org_id, :uuid, null: false)
      add(:apd_inserted_at, :utc_datetime, null: false)
      add(:apd_updated_at, :utc_datetime, null: false)
    end

    create(index(:apd_document, [:apd_org_id], name: "apd_document_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:apd_document, [:apd_org_id], name: "apd_document_org_idx"))
    drop(table(:apd_document))

    drop(index(:apv_approval, [:apv_state, :apv_deadline_at], name: "apv_approval_expiry_idx"))
    drop(index(:apv_approval, [:apv_org_id], name: "apv_approval_org_idx"))
    drop(unique_index(:apv_approval, [:apv_kind, :apv_subject_ref], name: "apv_approval_pending_global_idx"))

    drop(
      unique_index(:apv_approval, [:apv_org_id, :apv_kind, :apv_subject_ref],
        name: "apv_approval_pending_tenant_idx"
      )
    )

    drop(constraint(:apv_approval, :apv_distinct_party))
    drop(table(:apv_approval))
  end
end
