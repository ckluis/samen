defmodule Samen.WebTest.Repo.Migrations.SupportScopeOperatorArchivable do
  @moduledoc """
  ADR-040 §5.9 (T37f) — a SECOND, easy-to-miss Support mount discovered mid-run
  (the same class of discovery T37e made for a 5th primitives mount inside
  samen_core's own kernel test fixture): `samen_web/test/support/operator.ex`
  (`Samen.WebTest.Operator`) mounts Identity + Billing + Support a SECOND time
  in the SAME `Samen.WebTest.Repo` — the SaaS's OWN operator book-of-business
  namespace (ADR-010 §3.1), with its OWN `wq*`-prefixed Support abbrevs,
  entirely distinct from `Samen.WebTest.Support`'s `ws*` abbrevs already
  migrated in `20260729270000_support_scope_archivable.exs`. Not reachable by a
  static grep for `Samen.Scopes.Support` mount SITES alone if you stop at the
  first match — `mix test` surfaced the gap directly (`column "wqg_archived_at"
  does not exist`) when `Samen.WebTest.Operator.Agent`'s catalogued schema
  (post-blueprint-edit) outran this migration.

  Mirrors `20260729270000_support_scope_archivable.exs` exactly, for the `wq*`
  abbrev set: `ticket` (wqk), `conversation` (wqc), `message` (wqm), `agent`
  (wqg), `sla` (wql), `macro` (wqn) flip `archivable true`; `csat` (wqs) stays
  excluded. No `unique_index` exists on any of these six tables (confirmed by
  inspecting `20260708140000_mount_operator_scopes` — the only `unique_index`
  in that migration is on `wps_subscription`, Billing, unrelated) — nothing to
  convert to partial form.
  """
  use Samen.Migration

  def change do
    alter table(:wqk_ticket) do
      add(:wqk_archived_at, :utc_datetime_usec)
    end

    alter table(:wqc_conversation) do
      add(:wqc_archived_at, :utc_datetime_usec)
    end

    alter table(:wqm_message) do
      add(:wqm_archived_at, :utc_datetime_usec)
    end

    alter table(:wqg_agent) do
      add(:wqg_archived_at, :utc_datetime_usec)
    end

    alter table(:wql_sla) do
      add(:wql_archived_at, :utc_datetime_usec)
    end

    alter table(:wqn_macro) do
      add(:wqn_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Samen.WebTest.Operator.Ticket], only: [:archived_at])
    catalog_sync([Samen.WebTest.Operator.Conversation], only: [:archived_at])
    catalog_sync([Samen.WebTest.Operator.Message], only: [:archived_at])
    catalog_sync([Samen.WebTest.Operator.Agent], only: [:archived_at])
    catalog_sync([Samen.WebTest.Operator.Sla], only: [:archived_at])
    catalog_sync([Samen.WebTest.Operator.Macro], only: [:archived_at])
  end
end
