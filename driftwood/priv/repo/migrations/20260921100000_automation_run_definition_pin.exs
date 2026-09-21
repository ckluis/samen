defmodule Driftwood.Repo.Migrations.AutomationRunDefinitionPin do
  @moduledoc """
  T162 (ADR-039 §3.3/§8.1) — driftwood's mirror of the two additive
  `Automation.Run` columns (the samen_core `sar_run` / samen_web `war_run` twins).
  Driftwood is the first vertical adoption of `Samen.Scopes.Automation`, so its
  `dru_run` table has to carry the pin the shared kernel write path
  (`Samen.Automation.RunRecord`) now writes:

    * `dru_run.dru_definition` — the PINNED definition the run executed: the
      `actions`/`conditions`/`resource_key` snapshot taken at ENQUEUE by
      `Samen.Automation.DispatchWorker` and copied onto the row from the job args, so
      a tenant edit landing between enqueue and execution (or between retries) cannot
      change what an already-triggered run executes, and the historical row is
      interpretable against the definition that actually ran.
    * `dru_run.dru_definition_digest` — that definition's content identity (sha256
      over a canonical encoding, `Samen.Automation.Definition.digest/1`).

  Still no PII on the table: the definition is a byte-copy of three Workflow columns
  that are non-PII BY SCHEMA (the write-time `Samen.Automation.NonPiiPredicates`
  refusal makes a vault-routed or plaintext attribute structurally unreferenceable in
  a workflow) — rule STRUCTURE only, never a subject value, so ADR-039 §13's
  undo-snapshot rejection (prior subject attribute values, INV-1) is untouched.

  Additive + nullable on an already-catalogued resource → `catalog_sync/2` `only:`
  scoping, `change/0`-reversible. No abbrev-registry allocation: the existing `dru`
  owner is reused, no new resource.
  """
  use Samen.Migration

  def change do
    alter table(:dru_run) do
      add(:dru_definition, :map)
      add(:dru_definition_digest, :text)
    end

    catalog_sync([Driftwood.Automation.Run], only: [:definition, :definition_digest])
  end
end
