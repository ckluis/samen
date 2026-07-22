defmodule Driftwood.Repo.Migrations.WidenSessionInsertedAtUsec do
  @moduledoc """
  ADR-035 §4.3 A4 (T104) — widen the driftwood host's `Identity.Session` creation
  timestamp (`dos_inserted_at`) from second precision (`:utc_datetime`) to
  MICROSECOND precision (`:utc_datetime_usec`) so the org concurrent-session cap
  eviction (`Samen.Auth.SessionCreate.evict_to_cap`) sorts a STRICT TOTAL ORDER
  and always revokes the genuinely-oldest live session.

  Sibling-host mirror of
  `samen_web/priv/repo/migrations/20260722030000_widen_session_inserted_at_usec.exs`,
  adapted to driftwood's `dos` abbrev. Existing rows widen losslessly; no
  `catalog_sync` (only the precision of an already-cataloged column changes).
  See that migration's moduledoc for the full rationale (same-second sign-ins
  tied at second precision → arbitrary eviction).
  """
  use Ecto.Migration

  def up do
    alter table(:dos_session) do
      modify(:dos_inserted_at, :utc_datetime_usec, from: :utc_datetime, null: false)
    end
  end

  def down do
    alter table(:dos_session) do
      modify(:dos_inserted_at, :utc_datetime, from: :utc_datetime_usec, null: false)
    end
  end
end
