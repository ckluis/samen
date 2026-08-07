defmodule Samen.WebTest.Repo.Migrations.AddSupportCsatSurveyToken do
  @moduledoc """
  I6 (spec §I6, T79) — mounts the `scw_csat_survey_token` table onto the
  samen_web TEST-support Support mount (`Samen.WebTest.Support`): the
  single-use, expiring, hashed-at-rest CSAT survey link that closes the CSAT
  loop's request→response half (`Samen.Scopes.Support.Blueprint.
  define_csat_survey_token/7`). Catalogs it in the SAME migration transaction
  as the DDL, same discipline as `20260708130000_mount_billing_support_scopes.exs`.

  No PII. FK order: `wsk_ticket ← scw_csat_survey_token → wsg_agent`.
  """
  use Samen.Migration

  @resources [
    Samen.WebTest.Support.CsatSurveyToken
  ]

  def up do
    create table(:scw_csat_survey_token, primary_key: false) do
      add(:scw_token_digest, :text, null: false)
      add(:scw_expires_at, :utc_datetime, null: false)
      add(:scw_consumed_at, :utc_datetime)
      add(:scw_sent_at, :utc_datetime)

      add(
        :scw_ticket_id,
        references(:wsk_ticket,
          column: :wsk_id,
          name: "scw_csat_survey_token_scw_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :scw_agent_id,
        references(:wsg_agent,
          column: :wsg_id,
          name: "scw_csat_survey_token_scw_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:scw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:scw_org_id, :uuid, null: false)
      add(:scw_inserted_at, :utc_datetime, null: false)
      add(:scw_updated_at, :utc_datetime, null: false)
    end

    create(index(:scw_csat_survey_token, [:scw_token_digest], name: "scw_csat_survey_token_digest_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:scw_csat_survey_token, [:scw_token_digest], name: "scw_csat_survey_token_digest_idx"))
    drop(constraint(:scw_csat_survey_token, "scw_csat_survey_token_scw_agent_id_fkey"))
    drop(constraint(:scw_csat_survey_token, "scw_csat_survey_token_scw_ticket_id_fkey"))
    drop(table(:scw_csat_survey_token))
  end
end
