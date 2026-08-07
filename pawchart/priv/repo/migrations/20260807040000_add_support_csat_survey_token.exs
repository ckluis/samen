defmodule PawChart.Repo.Migrations.AddSupportCsatSurveyToken do
  @moduledoc """
  I6 (spec §I6, T79) — mounts the `psc_csat_survey_token` table onto
  PawChart's Support mount (`PawChart.Support`): the single-use, expiring,
  hashed-at-rest CSAT survey link that closes the CSAT loop's
  request→response half (`Samen.Scopes.Support.Blueprint.
  define_csat_survey_token/7`). Catalogs it in the SAME migration transaction
  as the DDL, same discipline as `20260708200000_pawchart_crm_support_scopes.exs`.

  No PII. FK order: `vsa_ticket ← psc_csat_survey_token → vsd_agent`.
  """
  use Samen.Migration

  @resources [
    PawChart.Support.CsatSurveyToken
  ]

  def up do
    create table(:psc_csat_survey_token, primary_key: false) do
      add(:psc_token_digest, :text, null: false)
      add(:psc_expires_at, :utc_datetime, null: false)
      add(:psc_consumed_at, :utc_datetime)
      add(:psc_sent_at, :utc_datetime)

      add(
        :psc_ticket_id,
        references(:vsa_ticket,
          column: :vsa_id,
          name: "psc_csat_survey_token_psc_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :psc_agent_id,
        references(:vsd_agent,
          column: :vsd_id,
          name: "psc_csat_survey_token_psc_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:psc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:psc_org_id, :uuid, null: false)
      add(:psc_inserted_at, :utc_datetime, null: false)
      add(:psc_updated_at, :utc_datetime, null: false)
    end

    create(index(:psc_csat_survey_token, [:psc_token_digest], name: "psc_csat_survey_token_digest_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:psc_csat_survey_token, [:psc_token_digest], name: "psc_csat_survey_token_digest_idx"))
    drop(constraint(:psc_csat_survey_token, "psc_csat_survey_token_psc_agent_id_fkey"))
    drop(constraint(:psc_csat_survey_token, "psc_csat_survey_token_psc_ticket_id_fkey"))
    drop(table(:psc_csat_survey_token))
  end
end
