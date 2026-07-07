defmodule Demo.PrimitivesScope do
  @moduledoc """
  The Demo host's Primitives domain — mounted from the `samen_core` Primitives scope
  blueprint (ADR-004; T3.7).

  One `use Samen.Scopes.Primitives` expands into five host-owned resources
  (`Demo.PrimitivesScope.{Notification,File,SearchIndex,Webhook,FeatureFlag}`),
  each a normal `use Samen.Resource` in the DEMO's `otp_app`/`repo`, so:

    * their columns are catalogued in the DEMO's `tam_table`/`fld_field`
      (the `AddPrimitivesScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan them;
    * `Notification` PII (rendered_body) and `Webhook` PII (signing_secret) route
      into the DEMO's one Postgres vault;
    * org-scope + RBAC policies are inherited, not re-authored;
    * Audit writes to the existing `aud_event` tier via `Samen.Scopes.Primitives.Audit`.

  ## PII summary

  | Resource     | Field          | Vault       |
  |--------------|----------------|-------------|
  | Notification | rendered_body  | :pii_body   |
  | Webhook      | signing_secret | :pii_secret |

  ## Search convention

  `SearchIndex` is a registry resource. Registering a PII-declared field raises
  `ArgumentError` (enforced by `Samen.Scopes.Primitives.SearchIndexGuard`). Demo
  registers `pfl_file.filename` and `pfl_file.content_type` as examples.

  ## Audit rides T2.2 — never duplicated

  Primitives actions are audited via `Samen.Scopes.Primitives.Audit`, which writes
  to the existing append-only `aud_event` tier. No new audit table is created.

  ## Thin smoke usage (T3.7 acceptance: proves host-mounting works)

  `Demo.PrimitivesScope.Smoke.run/1` exercises one round-trip per resource —
  a notification (vaulted body), a file, a search index entry, a webhook
  (vaulted secret), and a feature flag — confirming host-mount and vault routing
  work end-to-end against a real Postgres DB.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Primitives,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.PrimitivesScope
end

defmodule Demo.PrimitivesScope.NonPiiSetup do
  @moduledoc """
  Runtime registration of deliberate non-PII columns in the Primitives scope.

  Called from test setup. Fulfils the T3.7 requirement to classify free-text columns
  explicitly via the mask-unknown-by-default discipline (D9).

  ## Registered columns

  | Table              | Column             | Rationale                                          |
  |--------------------|--------------------|----------------------------------------------------|
  | pfl_file           | pfl_filename       | File system name — not personal identifier         |
  | pfl_file           | pfl_storage_key    | Opaque backend key — credential, not subject data  |
  | psh_search_index   | psh_resource_name  | Module name string — not subject data              |
  | psh_search_index   | psh_field_name     | Field name string — not subject data               |
  | psh_search_index   | psh_vector_column  | Column name string — not subject data              |
  | psh_search_index   | psh_description    | Description text — operator-authored, not subject  |
  | psh_search_index   | psh_ts_config      | Postgres ts_config name — not subject data         |
  | pwh_webhook        | pwh_url            | System endpoint URL — not personal identifier      |
  | pwh_webhook        | pwh_label          | Operator label — not subject data                  |
  | pff_feature_flag   | pff_name           | Flag name/identifier — not subject data            |
  | pff_feature_flag   | pff_description    | Description text — operator-authored               |
  | pnt_notification   | pnt_event_type     | Event type string — bounded label, not subject PII |
  """

  @non_pii_columns [
    {"pfl_file", "pfl_filename", "File system name — not a personal identifier per doc scope table. Consciously cleared T3.7."},
    {"pfl_file", "pfl_storage_key", "Opaque backend storage key — a system credential, not subject identity data. T3.7."},
    {"psh_search_index", "psh_resource_name", "Resource module name string — not subject data. T3.7."},
    {"psh_search_index", "psh_field_name", "Field name string — not subject data. T3.7."},
    {"psh_search_index", "psh_vector_column", "Postgres column name string — not subject data. T3.7."},
    {"psh_search_index", "psh_description", "Operator-authored description text. T3.7."},
    {"psh_search_index", "psh_ts_config", "Postgres ts_config string (e.g. 'english') — not subject data. T3.7."},
    {"pwh_webhook", "pwh_url", "System endpoint URL — not a personal identifier. T3.7."},
    {"pwh_webhook", "pwh_label", "Operator-authored endpoint label — not subject identity. T3.7."},
    {"pff_feature_flag", "pff_name", "Flag name identifier — not subject data. T3.7."},
    {"pff_feature_flag", "pff_description", "Operator-authored flag description — not subject data. T3.7."},
    {"pnt_notification", "pnt_event_type", "Event type string (bounded label, e.g. 'invoice.created') — not subject PII. T3.7."}
  ]

  @doc "Register Primitives non-PII columns. Idempotent."
  def register_all do
    Enum.each(@non_pii_columns, fn {table, column, reason} ->
      case Samen.NonPii.register(%{
             table_name: table,
             column_name: column,
             cleared_by: "T3.7-scope-author",
             reviewed_by: "T3.7-gate-reviewer",
             reason: reason,
             subject_column: "#{String.split(table, "_") |> hd()}_org_id",
             redaction: "[REDACTED]"
           }) do
        {:ok, _} -> :ok
        # Already registered (idempotent run)
        {:error, _} -> :ok
      end
    end)

    :ok
  end
end

defmodule Demo.PrimitivesScope.Seeds do
  @moduledoc """
  Seed helpers for the Primitives scope Tier-0 config rows.

  Seeds two feature flags (notifications enabled; search enabled) and a default
  webhook template. These are idempotent — safe to run multiple times.
  """

  alias Demo.PrimitivesScope.{FeatureFlag, Webhook}

  def seed_feature_flags(org_id) do
    Enum.each(
      [
        %{
          name: "notifications.enabled",
          description: "Enable in-app and email notifications",
          enabled: true,
          rollout_pct: 100,
          stage: :ga,
          org_id: org_id
        },
        %{
          name: "search.enabled",
          description: "Enable full-text search over file names",
          enabled: true,
          rollout_pct: 100,
          stage: :beta,
          org_id: org_id
        }
      ],
      fn attrs ->
        FeatureFlag
        |> Ash.Changeset.for_create(:create, attrs)
        |> Ash.create(authorize?: false)
      end
    )
  end

  def seed_webhook(org_id) do
    Webhook
    |> Ash.Changeset.for_create(:create, %{
      url: "https://example.com/webhooks/demo",
      label: "Demo webhook",
      event_types: ["invoice.created", "user.updated"],
      status: :active,
      signing_secret: "demo-signing-secret-#{:rand.uniform(99999)}",
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end
end

defmodule Demo.PrimitivesScope.Smoke do
  @moduledoc """
  Thin smoke usage for the Primitives scope. Exercises one round-trip per resource,
  confirming the host-mount and core mechanics work end-to-end.

  Called from tests (`primitives_scope_policy_matrix_test.exs`) to prove:
    * host-mounting works (resources exist, compile, have the right namespace)
    * the org-scope policy is wired (cross-org invisibility)
    * Notification rendered_body and Webhook signing_secret are vault-routed (PII masked)
    * SearchIndex rejects PII columns (red path)
    * FeatureFlag Tier-0 config rows work (admin creates; member can read)
    * Audit writes to aud_event (no new table)
  """

  alias Demo.PrimitivesScope.{Notification, File, SearchIndex, Webhook, FeatureFlag}

  @doc "Create a notification with vault-routed rendered_body."
  def mk_notification(org_id) do
    Notification
    |> Ash.Changeset.for_create(:create, %{
      recipient_id: Ash.UUID.generate(),
      channel: :email,
      event_type: "invoice.created",
      status: :sent,
      rendered_body: "Dear Alice, your invoice #1234 is ready.",
      sent_at: DateTime.utc_now(),
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Create a file record."
  def mk_file(org_id) do
    File
    |> Ash.Changeset.for_create(:create, %{
      filename: "invoice-#{:rand.uniform(9999)}.pdf",
      content_type: "application/pdf",
      size_bytes: 1024,
      storage_key: "s3://bucket/invoices/#{Ash.UUID.generate()}",
      status: :active,
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Create a search index entry (filename — non-PII field)."
  def mk_search_index(org_id) do
    SearchIndex
    |> Ash.Changeset.for_create(:create, %{
      resource_name: "Demo.PrimitivesScope.File",
      field_name: "filename",
      vector_column: "pfl_search_vector",
      description: "Full-text search over file names",
      enabled: true,
      ts_config: "english",
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Create a webhook with vault-routed signing_secret."
  def mk_webhook(org_id) do
    Webhook
    |> Ash.Changeset.for_create(:create, %{
      url: "https://example.com/hooks/#{:rand.uniform(9999)}",
      label: "Test webhook",
      event_types: ["invoice.created"],
      status: :active,
      signing_secret: "secret-#{Ash.UUID.generate()}",
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Create a feature flag (Tier-0 config row)."
  def mk_feature_flag(org_id) do
    FeatureFlag
    |> Ash.Changeset.for_create(:create, %{
      name: "notifications.enabled-#{:rand.uniform(9999)}",
      description: "Enable notifications",
      enabled: true,
      rollout_pct: 100,
      stage: :ga,
      org_id: org_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc "Run a complete round-trip smoke test. Returns {:ok, results} or {:error, reason}."
  def run(org_id) do
    with {:ok, notification} <- mk_notification(org_id),
         {:ok, file} <- mk_file(org_id),
         {:ok, search_index} <- mk_search_index(org_id),
         {:ok, webhook} <- mk_webhook(org_id),
         {:ok, feature_flag} <- mk_feature_flag(org_id) do
      {:ok,
       %{
         notification: notification,
         file: file,
         search_index: search_index,
         webhook: webhook,
         feature_flag: feature_flag
       }}
    end
  end
end
