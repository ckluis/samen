defmodule SamenCore.TestRepo.Migrations.AudChain do
  @moduledoc """
  T4.3 (ADR-002): the `aud_chain` hash-chained, tenant-readable, operator-uneditable
  audit chain — the linked table (abbrev `ach`) that seals reveal/impersonation/erasure
  `aud_event` rows into a per-org tamper-evident hash chain.

  ## T6.1 extraction (ADR-005)

  The full DDL body — the table, the dense per-org `(ach_org_id, ach_seq)` UNIQUE
  index, the tip-lookup index, the append-only trigger + function, the
  `REVOKE UPDATE, DELETE`, and the same-transaction `tam_table`/`fld_field` catalog
  rows — now lives ONCE in `Samen.OperatorPlane.Migration`. This migration (and the
  identical ones in `demo`/`driftwood`) used to carry a byte-identical copy of that
  DDL; the extraction retro found the 3-way copy-paste and collapsed it to a single
  shared definition. See `Samen.OperatorPlane.Migration` for the full documentation
  of what this creates and why (`ach_subject_ciphertext` = the per-subject
  key-destroyable ciphertext; `ach_ciphertext_sha256` = the digest the chain hash
  commits to, so a shred leaves the chain verifying).

  Plain `use Ecto.Migration` (not `use Samen.Migration`) because `aud_chain` is
  kernel infra backed by a plain `Ecto.Schema` (`Samen.AuditChain.Entry`), so the
  catalog rows are written via direct `execute/2` in the same transaction.
  """

  use Ecto.Migration

  @app_role Application.compile_env(:samen_core, :aud_event_app_role, "clank")

  def up, do: Samen.OperatorPlane.Migration.create_aud_chain(@app_role)
  def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(@app_role)
end
