defmodule Samen.Web.Repo.Migrations.WidenSessionInsertedAtUsec do
  @moduledoc """
  ADR-035 §4.3 A4 (T104) — widen the `Identity.Session` creation timestamp from
  second precision (`:utc_datetime`) to MICROSECOND precision
  (`:utc_datetime_usec`) so the org concurrent-session cap eviction
  (`Samen.Auth.SessionCreate.evict_to_cap`) sorts a STRICT TOTAL ORDER and always
  revokes the genuinely-oldest live session.

  At second precision, sign-ins minted in the same wall-clock second carried
  identical `inserted_at`, so the `sort(inserted_at: :asc)` tie resolved in
  arbitrary Postgres order and an ARBITRARY (not the oldest) session was evicted
  — a correctness gap that also made CI ~1-in-7 red. Widening this column gives
  same-second sign-ins a sub-second creation-order key; eviction now sorts
  `{inserted_at (µs), id}`.

  Sibling-host mirror migration per the T04/T07 no-deferral discipline. Existing
  rows widen losslessly (their second-precision values keep `.000000` µs). Plain
  additive-shape column type change — no `catalog_sync` (the column already
  exists on the cataloged table; only its precision changes).
  """
  use Ecto.Migration

  def up do
    alter table(:wos_session) do
      modify(:wos_inserted_at, :utc_datetime_usec, from: :utc_datetime, null: false)
    end
  end

  def down do
    alter table(:wos_session) do
      modify(:wos_inserted_at, :utc_datetime, from: :utc_datetime_usec, null: false)
    end
  end
end
