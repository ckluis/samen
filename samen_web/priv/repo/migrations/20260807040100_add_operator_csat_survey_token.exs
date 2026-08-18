defmodule Samen.WebTest.Repo.Migrations.AddOperatorCsatSurveyToken do
  @moduledoc """
  I6 (spec §I6, T79) — mounts the `wco_csat_survey_token` table onto the
  samen_web TEST-support OPERATOR Support mount (`Samen.WebTest.Operator`,
  ADR-010 §8.2): the operator-book sibling of
  `20260807040000_add_support_csat_survey_token.exs`, same shape, own FK
  targets (`wqk_ticket`/`wqg_agent`).

  No PII. FK order: `wqk_ticket ← wco_csat_survey_token → wqg_agent`.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Operator.CsatSurveyToken
  ]

  def up do
    create table(:wco_csat_survey_token, primary_key: false) do
      add(:wco_token_digest, :text, null: false)
      add(:wco_expires_at, :utc_datetime, null: false)
      add(:wco_consumed_at, :utc_datetime)
      add(:wco_sent_at, :utc_datetime)

      add(
        :wco_ticket_id,
        references(:wqk_ticket,
          column: :wqk_id,
          name: "wco_csat_survey_token_wco_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :wco_agent_id,
        references(:wqg_agent,
          column: :wqg_id,
          name: "wco_csat_survey_token_wco_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:wco_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wco_org_id, :uuid, null: false)
      add(:wco_inserted_at, :utc_datetime, null: false)
      add(:wco_updated_at, :utc_datetime, null: false)
    end

    create(index(:wco_csat_survey_token, [:wco_token_digest], name: "wco_csat_survey_token_digest_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:wco_csat_survey_token, [:wco_token_digest], name: "wco_csat_survey_token_digest_idx"))
    drop(constraint(:wco_csat_survey_token, "wco_csat_survey_token_wco_agent_id_fkey"))
    drop(constraint(:wco_csat_survey_token, "wco_csat_survey_token_wco_ticket_id_fkey"))
    drop(table(:wco_csat_survey_token))
  end
end
