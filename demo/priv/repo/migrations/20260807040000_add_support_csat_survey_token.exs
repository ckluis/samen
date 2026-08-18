defmodule Demo.Repo.Migrations.AddSupportCsatSurveyToken do
  @moduledoc """
  I6 (spec §I6, T79) — mounts the `dsc_csat_survey_token` table: the single-use,
  expiring, hashed-at-rest CSAT survey link that closes the CSAT loop's
  request→response half (`Samen.Scopes.Support.Blueprint.
  define_csat_survey_token/7`). Catalogs it in the SAME migration transaction
  as the DDL (ADR-004 §"Migrations" catalog-in-tx guarantee), same discipline
  as `20260706050000_add_support_scope.exs`.

  No PII: the token itself is an opaque 256-bit secret (only its SHA-256
  digest is stored); `ticket_id`/`agent_id` are opaque refs, matching
  `scs_csat`'s own FK shape exactly.

  ## FK order

  stk_ticket ← dsc_csat_survey_token → sag_agent
  """
  use Samen.Migration

  @resources [
    Demo.SupportScope.CsatSurveyToken
  ]

  def up do
    # --- dsc_csat_survey_token : single-use CSAT survey link ---
    create table(:dsc_csat_survey_token, primary_key: false) do
      add(:dsc_token_digest, :text, null: false)
      add(:dsc_expires_at, :utc_datetime, null: false)
      add(:dsc_consumed_at, :utc_datetime)
      add(:dsc_sent_at, :utc_datetime)

      add(
        :dsc_ticket_id,
        references(:stk_ticket,
          column: :stk_id,
          name: "dsc_csat_survey_token_dsc_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :dsc_agent_id,
        references(:sag_agent,
          column: :sag_id,
          name: "dsc_csat_survey_token_dsc_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:dsc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:dsc_org_id, :uuid, null: false)
      add(:dsc_inserted_at, :utc_datetime, null: false)
      add(:dsc_updated_at, :utc_datetime, null: false)
    end

    # A survey-response lookup is ALWAYS by digest (never by id) — the anonymous
    # redeem path's one and only query shape (`Samen.Scopes.Support.CsatSurvey.
    # preview/2`/`respond/4`).
    create(index(:dsc_csat_survey_token, [:dsc_token_digest], name: "dsc_csat_survey_token_digest_idx"))

    # --- catalog the new resource in THIS transaction ---
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(index(:dsc_csat_survey_token, [:dsc_token_digest], name: "dsc_csat_survey_token_digest_idx"))
    drop(constraint(:dsc_csat_survey_token, "dsc_csat_survey_token_dsc_agent_id_fkey"))
    drop(constraint(:dsc_csat_survey_token, "dsc_csat_survey_token_dsc_ticket_id_fkey"))
    drop(table(:dsc_csat_survey_token))
  end
end
