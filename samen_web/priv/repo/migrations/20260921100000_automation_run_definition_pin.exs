defmodule Samen.WebTest.Repo.Migrations.AutomationRunDefinitionPin do
  @moduledoc """
  T162 (ADR-039 §3.3/§8.1) — the samen_web test host's mirror of the two additive
  `Automation.Run` columns (samen_core's `sar_run` twin migration):

    * `war_run.war_definition` — the PINNED definition the run executed (the
      `actions`/`conditions`/`resource_key` snapshot taken at ENQUEUE and copied onto
      the row from the job args), so an edit landing between enqueue and execution
      cannot change what an already-triggered run does and the historical row stays
      interpretable.
    * `war_run.war_definition_digest` — that definition's content identity (sha256
      over a canonical encoding).

  Needed here because the operator health view reads REAL `war_run` rows
  (`operator_automation_health_test.exs` opens them through
  `Samen.Automation.RunRecord`, which now writes both columns) — without the columns
  the shared write path would fail on this host.

  Still no PII on the table: the definition is a byte-copy of three Workflow columns
  that are non-PII by schema (the `Samen.Automation.NonPiiPredicates` write-time
  refusal), rule structure only, never a subject value.

  Additive + nullable, `change/0`-reversible (the expand-`down/0` gate,
  `mix samen.verify.migrations`), `catalog_sync/2` scoped with `only:`. No abbrev
  allocation — the existing `war` owner is reused.
  """
  use Samen.Migration

  def change do
    alter table(:war_run) do
      add(:war_definition, :map)
      add(:war_definition_digest, :text)
    end

    catalog_sync([Samen.WebTest.Automation.Run], only: [:definition, :definition_digest])
  end
end
