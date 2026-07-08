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

  Demo-specific: app role is `"clank"` (the local dev/CI Postgres user).
  """

  use Ecto.Migration

  @app_role Application.compile_env(:demo, :aud_event_app_role, "clank")

  def up, do: Samen.OperatorPlane.Migration.create_aud_chain(@app_role)
  def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(@app_role)
end
