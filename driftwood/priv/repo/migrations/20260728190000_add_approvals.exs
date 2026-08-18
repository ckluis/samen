defmodule Driftwood.Repo.Migrations.AddApprovals do
  @moduledoc """
  T35 §4.7 — materializes the T34 E3 `Approval` resource (`Samen.Approvals.Blueprint`)
  on Driftwood's own repo: `fap_approval`, abbrev `fap` (allocator-reserved,
  `samen_core/priv/abbrev_registry.json` `hosts.driftwood.fap`; Driftwood's own
  f-prefixed convention avoids colliding with demo's `daa`).

  Driftwood is `Samen.Reveal.Grants`' engine client for the `"pii_reveal"` kind
  (`Samen.Reveal.ApprovalHandler`; registered in `config/config.exs`) — this is the table
  `Grants.approve/2` now writes through via `Samen.Approvals`.

  Shape mirrors `samen_core/priv/test_repo/migrations/20260728150000_approvals_fixture.exs`
  (the T34 in-tree reference; see `demo/priv/repo/migrations/20260728180000_add_approvals.exs`
  for the identically-shaped demo twin), minus the `apd_document` Gate-client table
  (samen_core-only) and the AshOban expiry-scan index (this host's `Approval` resource
  carries no `:expire` action — see `Samen.Approvals.Blueprint` moduledoc for why).
  """
  use Samen.Migration

  @resources [Driftwood.Approvals.Approval]

  def up do
    create table(:fap_approval, primary_key: false) do
      # NULL = plane-global governance approval (reveal); non-NULL = tenant-plane (§4.1).
      add(:fap_org_id, :uuid)
      add(:fap_kind, :text, null: false)
      add(:fap_subject_ref, :text, null: false)
      add(:fap_requested_by, :text, null: false)
      add(:fap_decided_by, :text)
      add(:fap_reason, :text)
      add(:fap_deadline_at, :utc_datetime_usec)
      add(:fap_requested_at, :utc_datetime_usec)
      add(:fap_decided_at, :utc_datetime_usec)
      add(:fap_state, :text, null: false, default: "pending")
      add(:fap_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fap_inserted_at, :utc_datetime, null: false)
      add(:fap_updated_at, :utc_datetime, null: false)
    end

    # Distinct-party DB CHECK — the rvg_distinct_party twin (§4.2 layer 2), carrying the
    # T34-F1 tightening: a DECIDED row (approved | rejected) MUST carry a non-NULL approver.
    create(
      constraint(:fap_approval, :fap_distinct_party,
        check: """
        (fap_decided_by IS NULL OR fap_decided_by <> fap_requested_by)
        AND (fap_state NOT IN ('approved', 'rejected') OR fap_decided_by IS NOT NULL)
        """
      )
    )

    create(
      unique_index(:fap_approval, [:fap_org_id, :fap_kind, :fap_subject_ref],
        where: "fap_state = 'pending' AND fap_org_id IS NOT NULL",
        name: "fap_approval_pending_tenant_idx"
      )
    )

    create(
      unique_index(:fap_approval, [:fap_kind, :fap_subject_ref],
        where: "fap_state = 'pending' AND fap_org_id IS NULL",
        name: "fap_approval_pending_global_idx"
      )
    )

    create(index(:fap_approval, [:fap_org_id], name: "fap_approval_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:fap_approval, [:fap_org_id], name: "fap_approval_org_idx"))

    drop(
      unique_index(:fap_approval, [:fap_kind, :fap_subject_ref],
        name: "fap_approval_pending_global_idx"
      )
    )

    drop(
      unique_index(:fap_approval, [:fap_org_id, :fap_kind, :fap_subject_ref],
        name: "fap_approval_pending_tenant_idx"
      )
    )

    drop(constraint(:fap_approval, :fap_distinct_party))
    drop(table(:fap_approval))
  end
end
