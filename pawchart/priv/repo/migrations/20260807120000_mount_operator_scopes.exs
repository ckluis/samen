defmodule PawChart.Repo.Migrations.MountOperatorScopes do
  @moduledoc """
  T157 (ADR-010 §8.2) — mounts PawChart's OPERATOR namespace into the vet host's one Postgres:
  a SECOND mount of Identity + Billing + Support whose rows describe the SaaS company's OWN book
  of business — its clinic-org ACCOUNTS, their clinic-ADMINS (PII the SaaS owns, CLEAR), each
  clinic's subscription-to-the-SaaS, and the tickets clinics file WITH the SaaS.

  Fresh `po*` (Identity) / `pm*` (Billing) / `pq*` (Support) abbrevs — append-only registry rows
  reserved via `mix samen.abbrev.reserve` (ADR-023). Catalogued in the SAME transaction
  (ADR-004 catalog-in-tx). This is the CURRENT accumulated blueprint shape (identity spine
  credential/auth_token/session/user_identity/login_failure, Money price, archivable support,
  onboarded/session-cap org fields), authored in one file since pawchart mounts the namespace fresh.

  PII columns hold vault `vt_*` tokens (plaintext never lands here):
    * `pou_user.pou_full_name` / `pou_user.pou_emails`  — the clinic-admin's name/email
    * `pmc_customer.pii_pmc_billing_name` / `pii_pmc_billing_email`
    * `pqg_agent.pqg_full_name` / `pii_pqg_email`, `pqm_message.pii_pqm_body`
    * `poc_credential.pii_poc_totp_secret` / `pii_poc_recovery_codes`, `pon_invitation.pon_email`
  """
  use Samen.Migration

  @resources [
    PawChart.Operator.Org,
    PawChart.Operator.Credential,
    PawChart.Operator.User,
    PawChart.Operator.Membership,
    PawChart.Operator.Role,
    PawChart.Operator.ApiKey,
    PawChart.Operator.Invitation,
    PawChart.Operator.AuthToken,
    PawChart.Operator.Session,
    PawChart.Operator.UserIdentity,
    PawChart.Operator.LoginFailure,
    PawChart.Operator.Customer,
    PawChart.Operator.Plan,
    PawChart.Operator.Price,
    PawChart.Operator.Subscription,
    PawChart.Operator.Invoice,
    PawChart.Operator.Payment,
    PawChart.Operator.Usage,
    PawChart.Operator.Entitlement,
    PawChart.Operator.SubscriptionEvent,
    PawChart.Operator.Sla,
    PawChart.Operator.Ticket,
    PawChart.Operator.Conversation,
    PawChart.Operator.Agent,
    PawChart.Operator.Message,
    PawChart.Operator.Macro,
    PawChart.Operator.Csat,
    PawChart.Operator.CsatSurveyToken
  ]

  def up do
    create table(:poo_org, primary_key: false) do
      add(:poo_max_concurrent_sessions, :integer)
      add(:poo_name, :text)
      add(:poo_onboarded_at, :utc_datetime)
      add(:poo_plan, :text)
      add(:poo_slug, :text)
      add(:poo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:poo_org_id, :uuid)
      add(:poo_inserted_at, :utc_datetime, null: false)
      add(:poo_updated_at, :utc_datetime, null: false)
    end

    create table(:poc_credential, primary_key: false) do
      add(:poc_email_bidx, :text)
      add(:poc_hash_scheme, :text)
      add(:poc_password_hash, :text)
      add(:poc_totp_enabled_at, :utc_datetime)
      add(:poc_totp_last_verified_at, :utc_datetime)
      add(:poc_verified_at, :utc_datetime)
      add(:pii_poc_recovery_codes, :text)
      add(:pii_poc_totp_secret, :text)
      add(:poc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:poc_org_id, :uuid)
      add(:poc_inserted_at, :utc_datetime, null: false)
      add(:poc_updated_at, :utc_datetime, null: false)
    end
    create(unique_index(:poc_credential, [:poc_email_bidx]))

    create table(:pou_user, primary_key: false) do
      add(:pou_credential_id, :uuid)
      add(:pou_emails, :text)
      add(:pou_full_name, :text)
      add(:pou_handle, :text)
      add(:pou_status, :text)
      add(:pou_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pou_org_id, :uuid, null: false)
      add(:pou_inserted_at, :utc_datetime, null: false)
      add(:pou_updated_at, :utc_datetime, null: false)
    end

    create table(:pom_membership, primary_key: false) do
      add(:pom_role, :text)
      add(:pom_status, :text)
      add(
        :pom_user_id,
        references(:pou_user,
          column: :pou_id,
          name: "pom_membership_pom_user_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pom_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pom_org_id, :uuid, null: false)
      add(:pom_inserted_at, :utc_datetime, null: false)
      add(:pom_updated_at, :utc_datetime, null: false)
    end

    create table(:por_role, primary_key: false) do
      add(:por_enabled, :boolean)
      add(:por_label, :text)
      add(:por_name, :text)
      add(:por_rank, :integer)
      add(:por_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:por_org_id, :uuid, null: false)
      add(:por_inserted_at, :utc_datetime, null: false)
      add(:por_updated_at, :utc_datetime, null: false)
    end

    create table(:pok_api_key, primary_key: false) do
      add(:pok_expires_at, :utc_datetime)
      add(:pok_last_used_at, :utc_datetime)
      add(
        :pok_membership_id,
        references(:pom_membership,
          column: :pom_id,
          name: "pok_api_key_pok_membership_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pok_minter_role, :text)
      add(:pok_plane, :text)
      add(:pok_revoked_at, :utc_datetime)
      add(:pok_scopes, :map)
      add(:pok_token_digest, :text)
      add(:pok_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pok_org_id, :uuid, null: false)
      add(:pok_inserted_at, :utc_datetime, null: false)
      add(:pok_updated_at, :utc_datetime, null: false)
    end

    create table(:pon_invitation, primary_key: false) do
      add(:pon_accepted_at, :utc_datetime)
      add(:pon_email, :text)
      add(:pon_email_bidx, :text)
      add(:pon_expires_at, :utc_datetime)
      add(:pon_revoked_at, :utc_datetime)
      add(:pon_role, :text)
      add(:pon_status, :text)
      add(:pon_token_digest, :text)
      add(:pon_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pon_org_id, :uuid, null: false)
      add(:pon_inserted_at, :utc_datetime, null: false)
      add(:pon_updated_at, :utc_datetime, null: false)
    end
    create(unique_index(:pon_invitation, [:pon_token_digest]))

    create table(:pot_auth_token, primary_key: false) do
      add(:pot_consumed_at, :utc_datetime)
      add(:pot_context, :text)
      add(
        :pot_credential_id,
        references(:poc_credential,
          column: :poc_id,
          name: "pot_auth_token_pot_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
      add(:pot_expires_at, :utc_datetime)
      add(:pot_sent_to_bidx, :text)
      add(:pot_token_digest, :text)
      add(:pot_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pot_org_id, :uuid)
      add(:pot_inserted_at, :utc_datetime, null: false)
      add(:pot_updated_at, :utc_datetime, null: false)
    end
    create(unique_index(:pot_auth_token, [:pot_token_digest]))

    create table(:pos_session, primary_key: false) do
      add(
        :pos_credential_id,
        references(:poc_credential,
          column: :poc_id,
          name: "pos_session_pos_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
      add(:pos_device_label, :text)
      add(:pos_expires_at, :utc_datetime)
      add(:pos_last_seen_at, :utc_datetime)
      add(:pos_revoked_at, :utc_datetime)
      add(:pos_token_digest, :text)
      add(:pos_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pos_org_id, :uuid)
      add(:pos_inserted_at, :utc_datetime_usec, null: false)
      add(:pos_updated_at, :utc_datetime, null: false)
    end
    create(unique_index(:pos_session, [:pos_token_digest]))

    create table(:poi_user_identity, primary_key: false) do
      add(
        :poi_credential_id,
        references(:poc_credential,
          column: :poc_id,
          name: "poi_user_identity_poi_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
      add(:poi_linked_at, :utc_datetime)
      add(:poi_provider, :text)
      add(:poi_provider_uid, :text)
      add(:poi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:poi_org_id, :uuid)
      add(:poi_inserted_at, :utc_datetime, null: false)
      add(:poi_updated_at, :utc_datetime, null: false)
    end
    create(unique_index(:poi_user_identity, [:poi_provider, :poi_provider_uid]))

    create table(:pol_login_failure, primary_key: false) do
      add(:pol_failure_count, :integer)
      add(:pol_key_kind, :text)
      add(:pol_key_value, :text)
      add(:pol_last_failed_at, :utc_datetime_usec)
      add(:pol_window_started_at, :utc_datetime_usec)
      add(:pol_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pol_org_id, :uuid)
      add(:pol_inserted_at, :utc_datetime, null: false)
      add(:pol_updated_at, :utc_datetime, null: false)
    end
    create(unique_index(:pol_login_failure, [:pol_key_kind, :pol_key_value]))

    create table(:pmc_customer, primary_key: false) do
      add(:pmc_currency, :text)
      add(:pmc_custom, :map)
      add(:pmc_provider_customer_ref, :text)
      add(:pmc_status, :text)
      add(:pii_pmc_billing_email, :text)
      add(:pii_pmc_billing_name, :text)
      add(:pmc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pmc_org_id, :uuid, null: false)
      add(:pmc_inserted_at, :utc_datetime, null: false)
      add(:pmc_updated_at, :utc_datetime, null: false)
    end

    create table(:pmp_plan, primary_key: false) do
      add(:pmp_archived_at, :utc_datetime_usec)
      add(:pmp_custom, :map)
      add(:pmp_description, :text)
      add(:pmp_enabled, :boolean)
      add(:pmp_features, :map)
      add(:pmp_interval, :text)
      add(:pmp_label, :text)
      add(:pmp_name, :text)
      add(:pmp_provider_plan_ref, :text)
      add(:pmp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pmp_org_id, :uuid, null: false)
      add(:pmp_inserted_at, :utc_datetime, null: false)
      add(:pmp_updated_at, :utc_datetime, null: false)
    end

    create table(:pmr_price, primary_key: false) do
      add(:pmr_active, :boolean)
      add(:pmr_archived_at, :utc_datetime_usec)
      add(:pmr_custom, :map)
      add(:pmr_interval, :text)
      add(
        :pmr_plan_id,
        references(:pmp_plan,
          column: :pmp_id,
          name: "pmr_price_pmr_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pmr_provider_price_ref, :text)
      add(:pmr_unit_amount, :money_with_currency)
      add(:pmr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pmr_org_id, :uuid, null: false)
      add(:pmr_inserted_at, :utc_datetime, null: false)
      add(:pmr_updated_at, :utc_datetime, null: false)
    end

    create table(:pms_subscription, primary_key: false) do
      add(:pms_cancel_at, :utc_datetime)
      add(:pms_cancelled_at, :utc_datetime)
      add(:pms_current_period_end, :utc_datetime)
      add(:pms_current_period_start, :utc_datetime)
      add(:pms_custom, :map)
      add(
        :pms_customer_id,
        references(:pmc_customer,
          column: :pmc_id,
          name: "pms_subscription_pms_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(
        :pms_plan_id,
        references(:pmp_plan,
          column: :pmp_id,
          name: "pms_subscription_pms_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pms_provider_subscription_ref, :text)
      add(:pms_status, :text)
      add(:pms_trial_end, :utc_datetime)
      add(:pms_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pms_org_id, :uuid, null: false)
      add(:pms_inserted_at, :utc_datetime, null: false)
      add(:pms_updated_at, :utc_datetime, null: false)
    end
    create(unique_index(:pms_subscription, [:pms_provider_subscription_ref], name: "pms_subscription_provider_ref_index"))

    create table(:pmi_invoice, primary_key: false) do
      add(:pmi_amount_due_cents, :integer)
      add(:pmi_amount_paid_cents, :integer)
      add(:pmi_currency, :text)
      add(:pmi_custom, :map)
      add(
        :pmi_customer_id,
        references(:pmc_customer,
          column: :pmc_id,
          name: "pmi_invoice_pmi_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pmi_due_date, :utc_datetime)
      add(:pmi_hosted_invoice_url, :text)
      add(:pmi_hosted_receipt_url, :text)
      add(:pmi_last_event_id, :text)
      add(:pmi_line_items, {:array, :map})
      add(:pmi_paid_at, :utc_datetime)
      add(:pmi_period_end, :utc_datetime)
      add(:pmi_period_start, :utc_datetime)
      add(:pmi_provider_invoice_ref, :text)
      add(:pmi_status, :text)
      add(
        :pmi_subscription_id,
        references(:pms_subscription,
          column: :pms_id,
          name: "pmi_invoice_pmi_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pmi_tax_amount_cents, :integer)
      add(:pmi_tax_lines, {:array, :map})
      add(:pmi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pmi_org_id, :uuid, null: false)
      add(:pmi_inserted_at, :utc_datetime, null: false)
      add(:pmi_updated_at, :utc_datetime, null: false)
    end

    create table(:pmy_payment, primary_key: false) do
      add(:pmy_amount_cents, :integer)
      add(:pmy_currency, :text)
      add(:pmy_custom, :map)
      add(
        :pmy_customer_id,
        references(:pmc_customer,
          column: :pmc_id,
          name: "pmy_payment_pmy_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pmy_failure_code, :text)
      add(
        :pmy_invoice_id,
        references(:pmi_invoice,
          column: :pmi_id,
          name: "pmy_payment_pmy_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pmy_last4, :text)
      add(:pmy_paid_at, :utc_datetime)
      add(:pmy_payment_method_type, :text)
      add(:pmy_provider_payment_ref, :text)
      add(:pmy_status, :text)
      add(:pmy_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pmy_org_id, :uuid, null: false)
      add(:pmy_inserted_at, :utc_datetime, null: false)
      add(:pmy_updated_at, :utc_datetime, null: false)
    end

    create table(:pmu_usage, primary_key: false) do
      add(:pmu_metric, :text)
      add(:pmu_period_end, :utc_datetime)
      add(:pmu_period_start, :utc_datetime)
      add(:pmu_quantity, :integer)
      add(:pmu_reported_at, :utc_datetime)
      add(
        :pmu_subscription_id,
        references(:pms_subscription,
          column: :pms_id,
          name: "pmu_usage_pmu_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pmu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pmu_org_id, :uuid, null: false)
      add(:pmu_inserted_at, :utc_datetime, null: false)
      add(:pmu_updated_at, :utc_datetime, null: false)
    end

    create table(:pme_entitlement, primary_key: false) do
      add(:pme_custom, :map)
      add(:pme_expires_at, :utc_datetime)
      add(:pme_feature, :text)
      add(:pme_granted, :boolean)
      add(
        :pme_plan_id,
        references(:pmp_plan,
          column: :pmp_id,
          name: "pme_entitlement_pme_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(
        :pme_subscription_id,
        references(:pms_subscription,
          column: :pms_id,
          name: "pme_entitlement_pme_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pme_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pme_org_id, :uuid, null: false)
      add(:pme_inserted_at, :utc_datetime, null: false)
      add(:pme_updated_at, :utc_datetime, null: false)
    end

    create table(:pmv_subscription_event, primary_key: false) do
      add(:pmv_customer_id, :uuid)
      add(:pmv_from_plan_id, :uuid)
      add(:pmv_from_status, :text)
      add(:pmv_kind, :text)
      add(:pmv_mrr_after_cents, :integer)
      add(:pmv_mrr_before_cents, :integer)
      add(:pmv_mrr_delta_cents, :integer)
      add(:pmv_occurred_at, :utc_datetime_usec)
      add(:pmv_plan_id, :uuid)
      add(:pmv_reason, :text)
      add(:pmv_subscription_id, :uuid, null: false)
      add(:pmv_to_status, :text)
      add(:pmv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pmv_org_id, :uuid, null: false)
      add(:pmv_inserted_at, :utc_datetime, null: false)
      add(:pmv_updated_at, :utc_datetime, null: false)
    end

    create table(:pql_sla, primary_key: false) do
      add(:pql_archived_at, :utc_datetime_usec)
      add(:pql_enabled, :boolean)
      add(:pql_first_response_minutes, :integer)
      add(:pql_label, :text)
      add(:pql_name, :text)
      add(:pql_priority, :text)
      add(:pql_resolve_minutes, :integer)
      add(:pql_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pql_org_id, :uuid, null: false)
      add(:pql_inserted_at, :utc_datetime, null: false)
      add(:pql_updated_at, :utc_datetime, null: false)
    end

    create table(:pqk_ticket, primary_key: false) do
      add(:pqk_archived_at, :utc_datetime_usec)
      add(:pqk_breached, :boolean)
      add(:pqk_closed_at, :utc_datetime)
      add(:pqk_custom, :map)
      add(:pqk_external_id, :text)
      add(:pqk_priority, :text)
      add(:pqk_resolved_at, :utc_datetime)
      add(:pqk_sla_breach_at, :utc_datetime)
      add(
        :pqk_sla_id,
        references(:pql_sla,
          column: :pql_id,
          name: "pqk_ticket_pqk_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pqk_status, :text)
      add(:pqk_subject, :text)
      add(:pqk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pqk_org_id, :uuid, null: false)
      add(:pqk_inserted_at, :utc_datetime, null: false)
      add(:pqk_updated_at, :utc_datetime, null: false)
    end
    create(index(:pqk_ticket, [:pqk_sla_breach_at, :pqk_breached], name: "pqk_ticket_sla_breach_idx", where: "pqk_sla_breach_at IS NOT NULL AND pqk_breached = false"))

    create table(:pqc_conversation, primary_key: false) do
      add(:pqc_archived_at, :utc_datetime_usec)
      add(:pqc_channel, :text)
      add(:pqc_status, :text)
      add(:pqc_subject, :text)
      add(
        :pqc_ticket_id,
        references(:pqk_ticket,
          column: :pqk_id,
          name: "pqc_conversation_pqc_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
      add(:pqc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pqc_org_id, :uuid, null: false)
      add(:pqc_inserted_at, :utc_datetime, null: false)
      add(:pqc_updated_at, :utc_datetime, null: false)
    end

    create table(:pqg_agent, primary_key: false) do
      add(:pqg_archived_at, :utc_datetime_usec)
      add(:pqg_custom, :map)
      add(:pqg_external_id, :text)
      add(:pqg_full_name, :text)
      add(:pqg_handle, :text)
      add(:pqg_role, :text)
      add(:pqg_status, :text)
      add(:pqg_timezone, :text)
      add(:pii_pqg_email, :text)
      add(:pqg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pqg_org_id, :uuid, null: false)
      add(:pqg_inserted_at, :utc_datetime, null: false)
      add(:pqg_updated_at, :utc_datetime, null: false)
    end

    create table(:pqm_message, primary_key: false) do
      add(
        :pqm_agent_id,
        references(:pqg_agent,
          column: :pqg_id,
          name: "pqm_message_pqm_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pqm_archived_at, :utc_datetime_usec)
      add(:pqm_attachments, {:array, :text})
      add(
        :pqm_conversation_id,
        references(:pqc_conversation,
          column: :pqc_id,
          name: "pqm_message_pqm_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
      add(:pqm_created_via, :text)
      add(:pqm_message_type, :text)
      add(:pqm_sender_id, :uuid)
      add(:pqm_sender_type, :text)
      add(:pii_pqm_body, :text)
      add(:pqm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pqm_org_id, :uuid, null: false)
      add(:pqm_inserted_at, :utc_datetime, null: false)
      add(:pqm_updated_at, :utc_datetime, null: false)
    end

    create table(:pqn_macro, primary_key: false) do
      add(:pqn_archived_at, :utc_datetime_usec)
      add(:pqn_body_template, :text)
      add(:pqn_category, :text)
      add(:pqn_description, :text)
      add(:pqn_enabled, :boolean)
      add(:pqn_name, :text)
      add(:pqn_tags, {:array, :text})
      add(:pqn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pqn_org_id, :uuid, null: false)
      add(:pqn_inserted_at, :utc_datetime, null: false)
      add(:pqn_updated_at, :utc_datetime, null: false)
    end

    create table(:pqs_csat, primary_key: false) do
      add(
        :pqs_agent_id,
        references(:pqg_agent,
          column: :pqg_id,
          name: "pqs_csat_pqs_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pqs_channel, :text)
      add(:pqs_comments, :text)
      add(:pqs_responded_at, :utc_datetime)
      add(:pqs_score, :integer)
      add(
        :pqs_ticket_id,
        references(:pqk_ticket,
          column: :pqk_id,
          name: "pqs_csat_pqs_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
      add(:pqs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pqs_org_id, :uuid, null: false)
      add(:pqs_inserted_at, :utc_datetime, null: false)
      add(:pqs_updated_at, :utc_datetime, null: false)
    end

    create table(:pqo_csat_survey_token, primary_key: false) do
      add(
        :pqo_agent_id,
        references(:pqg_agent,
          column: :pqg_id,
          name: "pqo_csat_survey_token_pqo_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
      add(:pqo_consumed_at, :utc_datetime)
      add(:pqo_expires_at, :utc_datetime)
      add(:pqo_sent_at, :utc_datetime)
      add(
        :pqo_ticket_id,
        references(:pqk_ticket,
          column: :pqk_id,
          name: "pqo_csat_survey_token_pqo_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
      add(:pqo_token_digest, :text)
      add(:pqo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pqo_org_id, :uuid, null: false)
      add(:pqo_inserted_at, :utc_datetime, null: false)
      add(:pqo_updated_at, :utc_datetime, null: false)
    end
    create(index(:pqo_csat_survey_token, [:pqo_token_digest], name: "pqo_csat_survey_token_digest_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:pqo_csat_survey_token))
    drop(table(:pqs_csat))
    drop(table(:pqn_macro))
    drop(table(:pqm_message))
    drop(table(:pqg_agent))
    drop(table(:pqc_conversation))
    drop(table(:pqk_ticket))
    drop(table(:pql_sla))
    drop(table(:pmv_subscription_event))
    drop(table(:pme_entitlement))
    drop(table(:pmu_usage))
    drop(table(:pmy_payment))
    drop(table(:pmi_invoice))
    drop(table(:pms_subscription))
    drop(table(:pmr_price))
    drop(table(:pmp_plan))
    drop(table(:pmc_customer))
    drop(table(:pol_login_failure))
    drop(table(:poi_user_identity))
    drop(table(:pos_session))
    drop(table(:pot_auth_token))
    drop(table(:pon_invitation))
    drop(table(:pok_api_key))
    drop(table(:por_role))
    drop(table(:pom_membership))
    drop(table(:pou_user))
    drop(table(:poc_credential))
    drop(table(:poo_org))
  end
end
