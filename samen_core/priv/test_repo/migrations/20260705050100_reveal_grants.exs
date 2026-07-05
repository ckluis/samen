defmodule SamenCore.TestRepo.Migrations.RevealGrants do
  @moduledoc """
  The T1.6 reveal-grant model tables (doc §control "'Time-boxed' is a built
  mechanism, not an adjective"; D6).

  Three tables, all abbrev-prefixed per the self-qualifying-storage idiom:

    * `rvq_reveal_request` — a requestor asks to reveal a subject's PII.
    * `rvg_reveal_grant`   — a DISTINCT party approves; carries `expires_at`
      (bounded default window) and `revoked_at` (auto-revoke flips this).
    * `rvl_reveal_audit`   — append-only lifecycle events (requested / granted /
      revoked / denied / expired). Plain rows now; the hash chain is Phase 4 (G4).

  ## The distinct-party DB CHECK (clause (b))

  `rvg_reveal_grant` carries a table CHECK: `rvg_granted_by <> rvg_requestor_id`.
  Self-approval is impossible AT THE DATABASE LEVEL, independent of any
  application policy — a `INSERT ... (granted_by = requestor_id)` raises a
  constraint violation even if the policy layer were bypassed or buggy. This is
  belt-and-suspenders with the `Samen.Reveal.Grants.approve/2` policy check
  (clause (b): enforced BOTH in policy AND by DB CHECK).

  ## No renew-in-place (clause (e))

  `expires_at` has NO update path in the grant model (`Samen.Reveal.Grants` ships
  no action that mutates it). Re-access requires a fresh request + fresh approval,
  which writes a NEW grant row. This migration does not add a trigger forbidding
  UPDATEs (that is Phase 2 append-only tier work for the audit table); the
  no-renew guarantee is enforced at the application layer where the red-path test
  proves an update attempt fails.
  """
  use Ecto.Migration

  def up do
    # ---- rvq_reveal_request -------------------------------------------------
    create table(:rvq_reveal_request, primary_key: false) do
      add(:rvq_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      # The subject whose PII the requestor wants to reveal.
      add(:rvq_subject_id, :string, null: false)
      # Who is asking (operator-class actor id).
      add(:rvq_requestor_id, :string, null: false)
      # Why (audited).
      add(:rvq_reason, :text, null: false)
      # Which resource/action the reveal is scoped to (nullable for coarse grants).
      add(:rvq_resource, :text)
      add(:rvq_action, :text)
      add(:rvq_status, :text, null: false, default: "pending")
      timestamps(type: :utc_datetime_usec, inserted_at: :rvq_inserted_at, updated_at: :rvq_updated_at)
    end

    create(index(:rvq_reveal_request, [:rvq_subject_id]))
    create(index(:rvq_reveal_request, [:rvq_requestor_id]))

    # ---- rvg_reveal_grant ---------------------------------------------------
    create table(:rvg_reveal_grant, primary_key: false) do
      add(:rvg_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      # FK back to the request that produced this grant.
      add(:rvg_request_id, :uuid, null: false)
      add(:rvg_subject_id, :string, null: false)
      # The requestor (copied from the request) and the DISTINCT approver.
      add(:rvg_requestor_id, :string, null: false)
      add(:rvg_granted_by, :string, null: false)
      add(:rvg_reason, :text, null: false)
      add(:rvg_resource, :text)
      add(:rvg_action, :text)
      # Bounded window: policy denies once now() > expires_at, even if the row
      # is never cleaned up (clause (c) — deny on read, not on cleanup).
      add(:rvg_expires_at, :utc_datetime_usec, null: false)
      # Auto-revoke (clause (d)) flips this at expires_at; also set on manual revoke.
      add(:rvg_revoked_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, inserted_at: :rvg_inserted_at, updated_at: :rvg_updated_at)
    end

    # CLAUSE (b): distinct-party approval enforced by DB CHECK. Self-approval is
    # impossible at the database level, independent of the policy layer.
    create(
      constraint(:rvg_reveal_grant, :rvg_distinct_party,
        check: "rvg_granted_by <> rvg_requestor_id"
      )
    )

    create(index(:rvg_reveal_grant, [:rvg_subject_id]))
    create(index(:rvg_reveal_grant, [:rvg_request_id]))
    create(index(:rvg_reveal_grant, [:rvg_expires_at]))

    # ---- rvl_reveal_audit (append-only lifecycle events) --------------------
    create table(:rvl_reveal_audit, primary_key: false) do
      add(:rvl_id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()"))
      # requested | granted | revoked | expired | denied
      add(:rvl_event, :text, null: false)
      add(:rvl_subject_id, :string, null: false)
      add(:rvl_actor_id, :string)
      add(:rvl_request_id, :uuid)
      add(:rvl_grant_id, :uuid)
      add(:rvl_detail, :text)
      add(:rvl_recorded_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(index(:rvl_reveal_audit, [:rvl_subject_id]))
    create(index(:rvl_reveal_audit, [:rvl_grant_id]))
  end

  def down do
    drop(table(:rvl_reveal_audit))
    drop(constraint(:rvg_reveal_grant, :rvg_distinct_party))
    drop(table(:rvg_reveal_grant))
    drop(table(:rvq_reveal_request))
  end
end
