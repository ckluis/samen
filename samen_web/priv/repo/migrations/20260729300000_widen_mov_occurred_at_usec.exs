defmodule Samen.Web.Repo.Migrations.WidenMovOccurredAtUsec do
  @moduledoc """
  ADR-017 (T121) — widen samen_web's subscription-movement ledger business timestamp
  `occurred_at` from second precision (`:utc_datetime`) to MICROSECOND precision
  (`:utc_datetime_usec`), for BOTH billing-ledger mounts in the framework's scratch
  DB: the tenant mount (abbrev `wbv`) and the operator mount (abbrev `wpv`).

  Sibling-host mirror of
  `demo/priv/repo/migrations/20260729300000_widen_mov_occurred_at_usec.exs`. Root
  cause: the ledger read sorts `(inserted_at, occurred_at)` but both were
  second-precision, so movements written inside one wall-clock second collapse to a
  single tied sort key → arbitrary Postgres order. `id` is a random UUIDv4 and cannot
  recover chronology; microsecond `occurred_at` restores a strict, chronological total
  order. Same class + fix shape as the T104 session-widen
  (`20260722030000_widen_session_inserted_at_usec.exs`). Existing rows widen
  losslessly; no `catalog_sync` (only column precision changes, not identity). Keeps
  the samen_web `SubscriptionEvent` mounts' DB columns in parity with the (now usec)
  shared blueprint attribute so the operator/revenue mov timelines order deterministically.
  """
  use Ecto.Migration

  def up do
    alter table(:wbv_subscription_event) do
      modify(:wbv_occurred_at, :utc_datetime_usec, from: :utc_datetime, null: false)
    end

    alter table(:wpv_subscription_event) do
      modify(:wpv_occurred_at, :utc_datetime_usec, from: :utc_datetime, null: false)
    end
  end

  def down do
    alter table(:wbv_subscription_event) do
      modify(:wbv_occurred_at, :utc_datetime, from: :utc_datetime_usec, null: false)
    end

    alter table(:wpv_subscription_event) do
      modify(:wpv_occurred_at, :utc_datetime, from: :utc_datetime_usec, null: false)
    end
  end
end
