defmodule Demo.Repo.Migrations.AudChain do
  @moduledoc """
  T4.3 (ADR-002): the `aud_chain` hash-chained, tenant-readable, operator-uneditable
  audit chain for the demo app.

  ## T6.1 extraction (ADR-005)

  The DDL body — table, per-org UNIQUE seq index, append-only trigger + role REVOKE,
  and the same-transaction catalog rows — is defined ONCE in
  `Samen.OperatorPlane.Migration.create_aud_chain/1`; this migration was a
  byte-identical copy before the extraction retro collapsed the 3-way copy-paste
  (samen_core test repo / demo / driftwood) into the shared helper. See that module
  for full documentation.

  Demo-specific: the app role is DERIVED at migration time (ADR-045 §4.2, O4; see
  `app_role/0`), never a hardcoded developer laptop role.
  """

  use Ecto.Migration

  # ADR-045 §4.2 (O4): DERIVE the app role at migration time (the `:aud_event_app_role` knob,
  # else the repo's configured `:username`, else RAISE) via the shared helper — NEVER a
  # hardcoded developer laptop role, which would ship a `REVOKE ... FROM <laptop-role>` into a
  # fresh prod deploy (whose first `release_command` then aborts: the role does not exist).
  defp app_role, do: Samen.OperatorPlane.Migration.app_role!(:demo, Demo.Repo)

  def up, do: Samen.OperatorPlane.Migration.create_aud_chain(app_role())
  def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(app_role())
end
