defmodule Demo.Repo.Migrations.AddApprovals do
  @moduledoc """
  T35 §4.7 — materializes the T34 E3 `Approval` resource (`Samen.Approvals.Blueprint`)
  on Demo's own repo: `daa_approval`, abbrev `daa` (allocator-reserved,
  `samen_core/priv/abbrev_registry.json` `hosts.demo.daa`).

  Demo is `Samen.Reveal.Grants`' engine client for the `"pii_reveal"` kind
  (`Samen.Reveal.ApprovalHandler`; registered in `config/config.exs`) — this is the table
  `Grants.approve/2` now writes through via `Samen.Approvals`.

  Shape mirrors `samen_core/priv/test_repo/migrations/20260728150000_approvals_fixture.exs`
  (the T34 in-tree reference), minus the `apd_document` Gate-client table (samen_core-only)
  and the AshOban expiry-scan index (this host's `Approval` resource carries no
  `:expire` action — see `Samen.Approvals.Blueprint` moduledoc for why).
  """
  use Samen.Migration

  @resources [Demo.Approvals.Approval]

  def up do
    create table(:daa_approval, primary_key: false) do
      # NULL = plane-global governance approval (reveal); non-NULL = tenant-plane (§4.1).
      add(:daa_org_id, :uuid)
      add(:daa_kind, :text, null: false)
      add(:daa_subject_ref, :text, null: false)
      add(:daa_requested_by, :text, null: false)
      add(:daa_decided_by, :text)
      add(:daa_reason, :text)
      add(:daa_deadline_at, :utc_datetime_usec)
      add(:daa_requested_at, :utc_datetime_usec)
      add(:daa_decided_at, :utc_datetime_usec)
      add(:daa_state, :text, null: false, default: "pending")
      add(:daa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:daa_inserted_at, :utc_datetime, null: false)
      add(:daa_updated_at, :utc_datetime, null: false)
    end

    # Distinct-party DB CHECK — the rvg_distinct_party twin (§4.2 layer 2), carrying the
    # T34-F1 tightening: a DECIDED row (approved | rejected) MUST carry a non-NULL approver.
    create(
      constraint(:daa_approval, :daa_distinct_party,
        check: """
        (daa_decided_by IS NULL OR daa_decided_by <> daa_requested_by)
        AND (daa_state NOT IN ('approved', 'rejected') OR daa_decided_by IS NOT NULL)
        """
      )
    )

    create(
      unique_index(:daa_approval, [:daa_org_id, :daa_kind, :daa_subject_ref],
        where: "daa_state = 'pending' AND daa_org_id IS NOT NULL",
        name: "daa_approval_pending_tenant_idx"
      )
    )

    create(
      unique_index(:daa_approval, [:daa_kind, :daa_subject_ref],
        where: "daa_state = 'pending' AND daa_org_id IS NULL",
        name: "daa_approval_pending_global_idx"
      )
    )

    create(index(:daa_approval, [:daa_org_id], name: "daa_approval_org_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:daa_approval, [:daa_org_id], name: "daa_approval_org_idx"))

    drop(
      unique_index(:daa_approval, [:daa_kind, :daa_subject_ref],
        name: "daa_approval_pending_global_idx"
      )
    )

    drop(
      unique_index(:daa_approval, [:daa_org_id, :daa_kind, :daa_subject_ref],
        name: "daa_approval_pending_tenant_idx"
      )
    )

    drop(constraint(:daa_approval, :daa_distinct_party))
    drop(table(:daa_approval))
  end
end
