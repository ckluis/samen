defmodule Driftwood.Repo.Migrations.AddOperatorCsatSurveyToken do
  @moduledoc """
  I6 (spec §I6, T79) — mounts the `dco_csat_survey_token` table onto
  Driftwood's OPERATOR Support mount (`Driftwood.Operator`, ADR-010 §8.1):
  the operator-book sibling of `20260807040000_add_support_csat_survey_token.exs`,
  same shape, own FK targets (`dqk_ticket`/`dqg_agent`).

  No PII. FK order: `dqk_ticket ← dco_csat_survey_token → dqg_agent`.
  """
  use Samen.Migration

  @resources [
    Driftwood.Operator.CsatSurveyToken
  ]

  def up do
    create table(:dco_csat_survey_token, primary_key: false) do
      add(:dco_token_digest, :text, null: false)
      add(:dco_expires_at, :utc_datetime, null: false)
      add(:dco_consumed_at, :utc_datetime)
      add(:dco_sent_at, :utc_datetime)

      add(
        :dco_ticket_id,
        references(:dqk_ticket,
          column: :dqk_id,
          name: "dco_csat_survey_token_dco_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :dco_agent_id,
        references(:dqg_agent,
          column: :dqg_id,
          name: "dco_csat_survey_token_dco_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dco_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dco_org_id, :uuid, null: false)
      add(:dco_inserted_at, :utc_datetime, null: false)
      add(:dco_updated_at, :utc_datetime, null: false)
    end

    create(index(:dco_csat_survey_token, [:dco_token_digest], name: "dco_csat_survey_token_digest_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:dco_csat_survey_token, [:dco_token_digest], name: "dco_csat_survey_token_digest_idx"))
    drop(constraint(:dco_csat_survey_token, "dco_csat_survey_token_dco_agent_id_fkey"))
    drop(constraint(:dco_csat_survey_token, "dco_csat_survey_token_dco_ticket_id_fkey"))
    drop(table(:dco_csat_survey_token))
  end
end
