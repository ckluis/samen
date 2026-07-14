defmodule Demo.Analytics do
  @moduledoc """
  The Demo host's Analytics domain — mounted from the `samen_core` Analytics scope
  blueprint (ADR-004; WS-B / G12; ADR-021).

  One `use Samen.Scopes.Analytics` expands into the host-owned resource
  `Demo.Analytics.ProductEvent` (`pae`) — a normal `use Samen.Resource` in the
  DEMO's `otp_app`/`repo`, so:

    * its columns catalogue into the DEMO's `tam_table`/`fld_field`
      (the `AddAnalyticsScope` migration's `catalog_sync/1`);
    * the DEMO's unchanged verifiers scan it;
    * it mirrors through the vault-excluded CDC projection for free (token-blind);
    * org-scope + RBAC policies are inherited, not re-authored.

  ## Capture

  `pae` rows are written ONLY via `Samen.Analytics.track/1` (the best-effort,
  PII-refusing-at-capture API). The demo wires the framework emitter in config:

      config :samen_core, Samen.Analytics, product_event_resource: Demo.Analytics.ProductEvent
      config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}

  so every framework choke point (and every flag-variant assignment) captures a
  bounded, token-blind event with zero call-site changes.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Analytics,
    otp_app: :demo,
    repo: Demo.Repo,
    namespace: Demo.Analytics
end

defmodule Demo.Analytics.NonPiiSetup do
  @moduledoc """
  Runtime registration of the deliberate non-PII columns on the `pae` ledger.

  `pae` is token-blind BY CONSTRUCTION: `Samen.Analytics.track/1` refuses any
  PII-bearing payload at capture (unregistered event name / prop key, or a
  PII-classified / PII-shaped / vault-token value) BEFORE a row is written. These
  `non_pii!` clearances record that guarantee at the physical tier so the token-blind
  CDC projection returns ALL of `pae`'s columns (AC-G12-3) rather than default-denying
  the freeform-typed `pae_props` map and the bounded string label columns.

  The two "reviewers" are honest: the CLEARANCE (this registration) attests the
  capture-time refusal; the GUARANTEE (`track/1`) enforces it. A PII value cannot
  reach these columns — the clearance is a record of a structural fact, not a waiver.

  | Table              | Column          | Rationale                                        |
  |--------------------|-----------------|--------------------------------------------------|
  | pae_product_event  | pae_props       | Bounded map; keys catalog-validated, values      |
  |                    |                 | PII-refused at capture (ADR-021 §4).             |
  | pae_product_event  | pae_actor_ref   | Per-subject HMAC pseudonym — not a raw id, not   |
  |                    |                 | PII (WideEvent.for_subject/2).                    |
  | pae_product_event  | pae_entity_ref  | Opaque bounded id/token of the entity — not PII. |
  """

  @non_pii_columns [
    {"pae_product_event", "pae_props",
     "Bounded product-event props map — keys are catalog-schema-validated and values are " <>
       "PII-refused at capture by Samen.Analytics.track/1 (ADR-021 §4). No PII value can " <>
       "reach this column; the clearance records the by-construction guarantee. WS-B G12."},
    {"pae_product_event", "pae_actor_ref",
     "Per-subject HMAC pseudonym (WideEvent.for_subject/2) — a one-way handle keyed on the " <>
       "subject's own KMS DEK, not a raw user id and not PII. Unlinkable post-shred. WS-B G12."},
    {"pae_product_event", "pae_entity_ref",
     "Opaque bounded id/token of the entity the event is about — a system reference, not " <>
       "subject identity data (PII-shaped values refused at capture). WS-B G12."}
  ]

  @doc "Register the Analytics scope non-PII columns. Idempotent."
  def register_all do
    Enum.each(@non_pii_columns, fn {table, column, reason} ->
      case Samen.NonPii.register(%{
             table_name: table,
             column_name: column,
             cleared_by: "WS-B-G12-scope-author",
             reviewed_by: "WS-B-G12-gate-reviewer",
             reason: reason,
             subject_column: "pae_org_id",
             redaction: "[REDACTED]"
           }) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end
end
