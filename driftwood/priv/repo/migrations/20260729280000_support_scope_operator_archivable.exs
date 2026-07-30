defmodule Driftwood.Repo.Migrations.SupportScopeOperatorArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37f) — a SECOND Support mount on Driftwood, easy to miss on a
  single-site grep (the same class of discovery as samen_web's
  `20260729280000_support_scope_operator_archivable.exs`): `driftwood/lib/
  driftwood/operator.ex` (`Driftwood.Operator`, ADR-010 §8.1) mounts Identity +
  Billing + Support a SECOND time in the SAME `Driftwood.Repo` — the SaaS's OWN
  operator book-of-business namespace, with its OWN `dq*`-prefixed Support
  abbrevs, entirely distinct from `Driftwood.Support`'s `fs*` abbrevs already
  migrated in `20260729270000_support_scope_archivable.exs`.

  Mirrors that migration exactly, for the `dq*` abbrev set: `ticket` (dqk),
  `conversation` (dqc), `message` (dqm), `agent` (dqg), `sla` (dql), `macro`
  (dqn) flip `archivable true`; `csat` (dqs) stays excluded. No `unique_index`
  exists on any of these six tables (confirmed by inspecting
  `20260708140000_mount_operator_scopes` — the only `unique_index` in
  Driftwood's operator-mount migration is on `dps_subscription`, Billing,
  unrelated) — nothing to convert to partial form.
  """
  use Samen.Migration

  def change do
    alter table(:dqk_ticket) do
      add(:dqk_archived_at, :utc_datetime_usec)
    end

    alter table(:dqc_conversation) do
      add(:dqc_archived_at, :utc_datetime_usec)
    end

    alter table(:dqm_message) do
      add(:dqm_archived_at, :utc_datetime_usec)
    end

    alter table(:dqg_agent) do
      add(:dqg_archived_at, :utc_datetime_usec)
    end

    alter table(:dql_sla) do
      add(:dql_archived_at, :utc_datetime_usec)
    end

    alter table(:dqn_macro) do
      add(:dqn_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Driftwood.Operator.Ticket], only: [:archived_at])
    catalog_sync([Driftwood.Operator.Conversation], only: [:archived_at])
    catalog_sync([Driftwood.Operator.Message], only: [:archived_at])
    catalog_sync([Driftwood.Operator.Agent], only: [:archived_at])
    catalog_sync([Driftwood.Operator.Sla], only: [:archived_at])
    catalog_sync([Driftwood.Operator.Macro], only: [:archived_at])
  end
end
