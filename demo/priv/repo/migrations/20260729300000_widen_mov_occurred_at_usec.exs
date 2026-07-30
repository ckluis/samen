defmodule Demo.Repo.Migrations.WidenMovOccurredAtUsec do
  @moduledoc """
  ADR-017 (T121) — widen the demo host's subscription-movement ledger business
  timestamp `mov_occurred_at` from second precision (`:utc_datetime`) to MICROSECOND
  precision (`:utc_datetime_usec`).

  Root cause of the pre-existing `subscription_movement_ledger_test.exs` flake: the
  ledger read sorts `(inserted_at, occurred_at)`, but BOTH were second-precision, so a
  rapid lifecycle (new → upgrade → downgrade → cancel → reactivate) writes every
  movement inside the same wall-clock second → one tied sort key across all rows →
  Postgres returns an ARBITRARY permutation of the tied group → the exact-order
  assertions flake. `mov_id` is a random UUIDv4 (not time-ordered) so it cannot
  recover chronology. Microsecond `occurred_at` gives each append a distinct
  business-time instant, making the ledger read a strict total order that respects
  real chronology.

  Same class + fix shape as the T104 session-eviction widen
  (`20260722030000_widen_session_inserted_at_usec.exs`). Existing rows widen
  losslessly; no `catalog_sync` (only the precision of an already-cataloged column
  changes, not its identity/logical name).
  """
  use Ecto.Migration

  def up do
    alter table(:mov_subscription_event) do
      modify(:mov_occurred_at, :utc_datetime_usec, from: :utc_datetime, null: false)
    end
  end

  def down do
    alter table(:mov_subscription_event) do
      modify(:mov_occurred_at, :utc_datetime, from: :utc_datetime_usec, null: false)
    end
  end
end
