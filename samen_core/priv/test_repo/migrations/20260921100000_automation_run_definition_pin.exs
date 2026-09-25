defmodule SamenCore.TestRepo.Migrations.AutomationRunDefinitionPin do
  @moduledoc """
  T162 (ADR-039 §3.3/§8.1) — two additive columns on the already-catalogued
  `sar_run` table, the fixture mount of the Automation scope's E8 `Run` log:

    * `sar_run.sar_definition` — the PINNED definition the run executed: the
      snapshot of the rule (`actions` / `conditions` / `resource_key`) taken at
      ENQUEUE by `Samen.Automation.DispatchWorker` and copied onto the row from the
      job args. A tenant edit landing between enqueue and execution (or between
      retries) can no longer change what an already-triggered run executes, and the
      historical row is interpretable against the definition that ACTUALLY ran
      instead of whatever the Workflow row says today.
    * `sar_run.sar_definition_digest` — that definition's content identity (sha256
      over a canonical encoding, `Samen.Automation.Definition.digest/1`), so the row
      is self-verifying and two runs of one definition share an identity.

  Still NO PII on this table (the `no_pii_columns` bar asserted directly against
  `information_schema` in `observability_test.exs`): the definition is a byte-copy of
  `Workflow.conditions`/`actions`/`resource_key`, three columns that are non-PII BY
  SCHEMA — the write-time `Samen.Automation.NonPiiPredicates` refusal makes a
  vault-routed or plaintext-PII attribute structurally unreferenceable in a workflow,
  and ADR-039 §13 rejects freeform to-addresses for the same reason. It carries rule
  STRUCTURE, never a subject value, so ADR-039 §13's undo-snapshot rejection (prior
  SUBJECT ATTRIBUTE VALUES, INV-1) is untouched.

  Additive, nullable columns on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping (the `arn_context_cutoff_tokens` precedent), reversible via
  `change/0`. Existing rows keep a NULL pin — they predate the pin and nothing
  pretends otherwise. No abbrev-registry allocation: no new resource, the existing
  `sar` owner is reused.
  """
  use Samen.Migration

  def change do
    alter table(:sar_run) do
      add(:sar_definition, :map)
      add(:sar_definition_digest, :text)
    end

    catalog_sync([SamenCore.Support.AutomationFixture.Run],
      only: [:definition, :definition_digest]
    )
  end
end
