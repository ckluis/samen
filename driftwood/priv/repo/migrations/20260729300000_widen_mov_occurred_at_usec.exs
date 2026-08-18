defmodule Driftwood.Repo.Migrations.WidenMovOccurredAtUsec do
  @moduledoc """
  ADR-017 (T121) — widen the driftwood host's subscription-movement ledger business
  timestamp `occurred_at` from second precision (`:utc_datetime`) to MICROSECOND
  precision (`:utc_datetime_usec`), for BOTH of driftwood's billing namespaces: the
  tenant mount (`Driftwood.Billing.SubscriptionEvent`, abbrev `fbv`) and the operator
  mount (`Driftwood.Operator.SubscriptionEvent`, abbrev `dpv`).

  Sibling-host mirror of
  `demo/priv/repo/migrations/20260729300000_widen_mov_occurred_at_usec.exs`. Root
  cause: the ledger read sorts `(inserted_at, occurred_at)` but both were
  second-precision, so a rapid subscription lifecycle collapses every movement to one
  tied sort key → arbitrary Postgres order → flaky exact-order assertions. `id` is a
  random UUIDv4 and cannot recover chronology. Microsecond `occurred_at` restores a
  strict, chronological total order. Same class + fix shape as the T104 session-widen
  (`20260722030000_widen_session_inserted_at_usec.exs`). Existing rows widen
  losslessly; no `catalog_sync` (only column precision changes, not identity).
  """
  use Ecto.Migration

  def up do
    alter table(:fbv_subscription_event) do
      modify(:fbv_occurred_at, :utc_datetime_usec, from: :utc_datetime, null: false)
    end

    alter table(:dpv_subscription_event) do
      modify(:dpv_occurred_at, :utc_datetime_usec, from: :utc_datetime, null: false)
    end
  end

  def down do
    alter table(:fbv_subscription_event) do
      modify(:fbv_occurred_at, :utc_datetime, from: :utc_datetime_usec, null: false)
    end

    alter table(:dpv_subscription_event) do
      modify(:dpv_occurred_at, :utc_datetime, from: :utc_datetime_usec, null: false)
    end
  end
end
