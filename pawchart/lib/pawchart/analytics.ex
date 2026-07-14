defmodule PawChart.Analytics do
  @moduledoc """
  PawChart's Analytics domain — mounted from the samen_core Analytics scope
  blueprint (ADR-004; WS-B / G12; ADR-021), exactly as `demo/` and `driftwood/`
  mount it (AC-X1 vertical-inheritance proof, B9). One `use Samen.Scopes.Analytics`
  expands into the host-owned resource `PawChart.Analytics.ProductEvent` — the
  governed, token-blind product-event ledger, in PAWCHART's `otp_app`/`repo`, so:

    * its columns catalogue into PawChart's `tam_table`/`fld_field`
      (the `AddAnalyticsScope` migration's `catalog_sync/1`);
    * PawChart's unchanged verifiers scan it;
    * org-scope + RBAC policies are inherited, not re-authored.

  ## Abbrev allocation (fresh abbrev — the built-substrate reality)

  The scope-default abbrev `pae` is owned by the demo mount in the single GLOBAL
  registry (`samen_core/priv/abbrev_registry.json`), so PawChart takes the FRESH
  abbrev `vae` (`v`-for-vet, the `vnt/vff` convention) via the blueprint's
  `abbrevs:` override. No samen_core CODE changed — the data-file registry gained
  PawChart's reserved row (append-only, ADR-006).

  ## Capture

  `vae` rows are written ONLY via `Samen.Analytics.track/1` (best-effort,
  PII-refusing-at-capture). PawChart wires the framework emitter in config:

      config :samen_core, Samen.Analytics, product_event_resource: PawChart.Analytics.ProductEvent
      config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}

  so every framework choke point (and every flag-variant assignment) captures a
  bounded, token-blind event with zero vertical call-site changes.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Analytics,
    otp_app: :pawchart,
    repo: PawChart.Repo,
    namespace: PawChart.Analytics,
    abbrevs: %{product_event: "vae"}
end

defmodule PawChart.Analytics.NonPiiSetup do
  @moduledoc """
  Runtime registration of the deliberate non-PII columns on PawChart's `vae`
  product-event ledger — the vertical mirror of `Demo.Analytics.NonPiiSetup`
  (WS-B G12; ADR-021). The CLEARANCE (this registration) attests the capture-time
  PII refusal; the GUARANTEE (`Samen.Analytics.track/1`) enforces it — a PII value
  cannot reach these columns, so the clearance records a structural fact.
  """

  @non_pii_columns [
    {"vae_product_event", "vae_props",
     "Bounded product-event props map — keys are catalog-schema-validated and values are " <>
       "PII-refused at capture by Samen.Analytics.track/1 (ADR-021 §4). No PII value can " <>
       "reach this column; the clearance records the by-construction guarantee. WS-B B9/AC-X1."},
    {"vae_product_event", "vae_actor_ref",
     "Per-subject HMAC pseudonym (WideEvent.for_subject/2) — a one-way handle keyed on the " <>
       "subject's own KMS DEK, not a raw user id and not PII. Unlinkable post-shred. WS-B B9/AC-X1."},
    {"vae_product_event", "vae_entity_ref",
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
             subject_column: "vae_org_id",
             redaction: "[REDACTED]"
           }) do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end)

    :ok
  end
end
