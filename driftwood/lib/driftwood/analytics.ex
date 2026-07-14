defmodule Driftwood.Analytics do
  @moduledoc """
  Driftwood's Analytics domain — mounted from the samen_core Analytics scope
  blueprint (ADR-004; WS-B / G12; ADR-021), exactly as `demo/` mounts it (AC-X1
  vertical-inheritance proof, B9). One `use Samen.Scopes.Analytics` expands into the
  host-owned resource `Driftwood.Analytics.ProductEvent` — the governed, token-blind
  product-event ledger, in DRIFTWOOD's `otp_app`/`repo`, so:

    * its columns catalogue into Driftwood's `tam_table`/`fld_field`
      (the `AddAnalyticsScope` migration's `catalog_sync/1`);
    * Driftwood's unchanged verifiers scan it;
    * it mirrors through the vault-excluded CDC projection for free (token-blind);
    * org-scope + RBAC policies are inherited, not re-authored.

  ## Abbrev allocation (fresh abbrev — the built-substrate reality)

  The scope-default abbrev `pae` is owned by the demo mount in the single GLOBAL
  registry (`samen_core/priv/abbrev_registry.json`), so Driftwood takes the FRESH
  abbrev `fae` (`f`-for-freight, the `fbc/fcm/fff` convention) via the blueprint's
  `abbrevs:` override. No samen_core CODE changed — the data-file registry gained
  Driftwood's reserved row (append-only, ADR-006).

  ## Capture

  `fae` rows are written ONLY via `Samen.Analytics.track/1` (best-effort,
  PII-refusing-at-capture). Driftwood wires the framework emitter in config:

      config :samen_core, Samen.Analytics, product_event_resource: Driftwood.Analytics.ProductEvent
      config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}

  so every framework choke point (and every flag-variant assignment) captures a
  bounded, token-blind event with zero vertical call-site changes.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Analytics,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Analytics,
    abbrevs: %{product_event: "fae"}
end

defmodule Driftwood.Analytics.NonPiiSetup do
  @moduledoc """
  Runtime registration of the deliberate non-PII columns on Driftwood's `fae`
  product-event ledger — the vertical mirror of `Demo.Analytics.NonPiiSetup`
  (WS-B G12; ADR-021). The CLEARANCE (this registration) attests the capture-time
  PII refusal; the GUARANTEE (`Samen.Analytics.track/1`) enforces it — a PII value
  cannot reach these columns, so the clearance records a structural fact.
  """

  @non_pii_columns [
    {"fae_product_event", "fae_props",
     "Bounded product-event props map — keys are catalog-schema-validated and values are " <>
       "PII-refused at capture by Samen.Analytics.track/1 (ADR-021 §4). No PII value can " <>
       "reach this column; the clearance records the by-construction guarantee. WS-B B9/AC-X1."},
    {"fae_product_event", "fae_actor_ref",
     "Per-subject HMAC pseudonym (WideEvent.for_subject/2) — a one-way handle keyed on the " <>
       "subject's own KMS DEK, not a raw user id and not PII. Unlinkable post-shred. WS-B B9/AC-X1."},
    {"fae_product_event", "fae_entity_ref",
     "Opaque bounded id/token of the entity the event is about — a system reference, not " <>
       "subject identity data (PII-shaped values refused at capture). WS-B B9/AC-X1."}
  ]

  @doc "Register the Analytics scope non-PII columns. Idempotent."
  def register_all do
    Enum.each(@non_pii_columns, fn {table, column, reason} ->
      case Samen.NonPii.register(%{
             table_name: table,
             column_name: column,
             cleared_by: "WS-B-B9-scope-author",
             reviewed_by: "WS-B-B9-gate-reviewer",
             reason: reason,
             subject_column: "fae_org_id",
             redaction: "[REDACTED]"
           }) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end
end
