defmodule Driftwood.Repo.Migrations.AudChain do
  @moduledoc """
  T4.3 (ADR-002): the `aud_chain` hash-chained, tenant-readable, operator-uneditable
  audit chain for the Driftwood reference vertical.

  ## T6.1 extraction (ADR-005)

  The DDL body — table, per-org UNIQUE seq index, append-only trigger + role REVOKE,
  and the same-transaction catalog rows — is defined ONCE in
  `Samen.OperatorPlane.Migration.create_aud_chain/1`. This migration was a
  byte-identical copy of the demo / samen_core versions; the extraction retro
  (T6.1) found the 3-way copy-paste of one security-critical table and collapsed it
  to the shared helper. See `Samen.OperatorPlane.Migration` for the full design docs.

  ## Why Driftwood needs this table (T5.4 finding)

  T5.2/T5.3 built the operator plane (impersonation sessions, reveal ledger) but did
  NOT migrate `aud_chain`. The reveal/impersonation/erasure writers
  (`Samen.AuditChain.Writer`) degrade gracefully when the table is absent (the
  `aud_event` row still lands, the chain entry is skipped) — so the app ran green
  without it. But the T5.4 crypto-shred game-day must PROVE the tamper-evident
  audit/impersonation chain still VERIFIES post-shred while the driver is
  unrecoverable (the doc's "immutable AND crypto-shreddable" resolution). That
  requires the chain to exist, so this migration deploys it. `ach_detail` is the
  deliberately-preserved plaintext token channel (ADR-002 §2.5);
  `ach_subject_ciphertext` is the per-subject key-destroyable column that makes the
  chain crypto-shreddable.

  Driftwood-specific: the app role is DERIVED at migration time (ADR-045 §4.2, O4; see
  `app_role/0`), never a hardcoded developer laptop role.
  """

  use Ecto.Migration

  # ADR-045 §4.2 (O4): DERIVE the app role at migration time (the `:aud_event_app_role` knob,
  # else the repo's configured `:username`, else RAISE) via the shared helper — NEVER a
  # hardcoded developer laptop role, which would ship a `REVOKE ... FROM <laptop-role>` into a
  # fresh prod deploy (whose first `release_command` then aborts: the role does not exist).
  defp app_role, do: Samen.OperatorPlane.Migration.app_role!(:driftwood, Driftwood.Repo)

  def up, do: Samen.OperatorPlane.Migration.create_aud_chain(app_role())
  def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(app_role())
end
