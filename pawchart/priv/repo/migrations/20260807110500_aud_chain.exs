defmodule PawChart.Repo.Migrations.AudChain do
  @moduledoc """
  O2 fix (ADR-045 §4.3): the `aud_chain` hash-chained, tenant-readable,
  operator-uneditable audit chain for the PawChart vet vertical.

  ## Why this was missing (the O2 finding)

  PawChart mounts the operator plane (`20260807110000_operator_plane_infra.exs`)
  and the reveal/impersonation/DSAR lifecycle, but never migrated `aud_chain` —
  demo (`20260707030000_aud_chain.exs`) and driftwood
  (`20260707200000_aud_chain.exs`) both have it, pawchart did not. So EVERY
  `Samen.AuditChain.append/2` on pawchart hit `relation "aud_chain" does not
  exist`, and the DSAR/reveal writers swallow that failure — non-repudiation was
  silently broken in the vet vertical (the tamper-evident chain simply did not
  exist). This migration deploys the table so appends PERSIST.

  ## Framework-first — the shared helper, NOT a hand-fork (ADR-005 / T6.1)

  The DDL body — table, per-org UNIQUE seq index, tip-lookup index, append-only
  trigger + role REVOKE, and the same-transaction catalog rows — is defined ONCE
  in `Samen.OperatorPlane.Migration.create_aud_chain/1`, the extraction that
  collapsed the demo / driftwood / samen_core copy-paste. PawChart adopts it the
  SAME way every other host does: wrap the shared body, own only the module, the
  otp_app, and the migration position. `ach_detail` is the deliberately-preserved
  plaintext token channel (ADR-002 §2.5); `ach_subject_ciphertext` is the
  per-subject key-destroyable column that makes the chain crypto-shreddable.

  PawChart-specific: the app role is read off pawchart's OWN otp_app (`:pawchart`) so
  the append-only `REVOKE`/`GRANT` names the host's Postgres role; it is DERIVED at
  migration time (ADR-045 §4.2, O4; see `app_role/0`), never a hardcoded laptop role.
  """

  use Ecto.Migration

  # ADR-045 §4.2 (O4): DERIVE the app role at migration time (the `:aud_event_app_role` knob,
  # else the repo's configured `:username`, else RAISE) via the shared helper — NEVER a
  # hardcoded developer laptop role, which would ship a `REVOKE ... FROM <laptop-role>` into a
  # fresh prod deploy (whose first `release_command` then aborts: the role does not exist).
  defp app_role, do: Samen.OperatorPlane.Migration.app_role!(:pawchart, PawChart.Repo)

  def up, do: Samen.OperatorPlane.Migration.create_aud_chain(app_role())
  def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(app_role())
end
