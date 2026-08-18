defmodule Driftwood.Repo.Migrations.AddSupportCsatSurveyToken do
  @moduledoc """
  I6 (spec §I6, T79) — mounts the `dcs_csat_survey_token` table onto
  Driftwood's TENANT Support mount (`Driftwood.Support`): the single-use,
  expiring, hashed-at-rest CSAT survey link that closes the CSAT loop's
  request→response half (`Samen.Scopes.Support.Blueprint.
  define_csat_survey_token/7`). Catalogs it in the SAME migration transaction
  as the DDL, same discipline as `20260708110000_mount_billing_support_scopes.exs`.

  No PII. FK order: `fsk_ticket ← dcs_csat_survey_token → fsa_agent`.
  """
  use Samen.Migration

  @resources [
    Driftwood.Support.CsatSurveyToken
  ]

  def up do
    create table(:dcs_csat_survey_token, primary_key: false) do
      add(:dcs_token_digest, :text, null: false)
      add(:dcs_expires_at, :utc_datetime, null: false)
      add(:dcs_consumed_at, :utc_datetime)
      add(:dcs_sent_at, :utc_datetime)

      add(
        :dcs_ticket_id,
        references(:fsk_ticket,
          column: :fsk_id,
          name: "dcs_csat_survey_token_dcs_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :dcs_agent_id,
        references(:fsa_agent,
          column: :fsa_id,
          name: "dcs_csat_survey_token_dcs_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dcs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dcs_org_id, :uuid, null: false)
      add(:dcs_inserted_at, :utc_datetime, null: false)
      add(:dcs_updated_at, :utc_datetime, null: false)
    end

    create(index(:dcs_csat_survey_token, [:dcs_token_digest], name: "dcs_csat_survey_token_digest_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:dcs_csat_survey_token, [:dcs_token_digest], name: "dcs_csat_survey_token_digest_idx"))
    drop(constraint(:dcs_csat_survey_token, "dcs_csat_survey_token_dcs_agent_id_fkey"))
    drop(constraint(:dcs_csat_survey_token, "dcs_csat_survey_token_dcs_ticket_id_fkey"))
    drop(table(:dcs_csat_survey_token))
  end
end
