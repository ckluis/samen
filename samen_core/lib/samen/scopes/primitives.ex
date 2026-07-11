defmodule Samen.Scopes.Primitives do
  @moduledoc """
  The **Primitives** universal scope (T3.7; doc §"The inherited 80%" scope table:
  `notification🔒 · file · search · audit · webhook🔒 · feature_flag`).

  Ships as a **library-authored blueprint** (ADR-004): `use`-ing this module
  inside a host's Ash domain expands into five host-owned resources in the host's
  namespace — each a normal `use Samen.Resource` with the host's `otp_app`,
  `repo`, and `domain`. Audit rides the T2.2 `aud_event` tier (no new table).

  ## PII map (🔒)

  | Resource     | Field          | Vault       | Note                                  |
  |--------------|----------------|-------------|---------------------------------------|
  | notification | rendered_body  | :pii_body   | scalar: rendered notification content |
  | webhook      | signing_secret | :pii_secret | scalar: HMAC signing secret           |

  Both route through the vault. `notification🔒` has rendered content that may
  contain PII (name, email, etc.); `webhook🔒` has a signing secret that is a
  credential (must not appear in logs/spans).

  ## Search — tokenized index convention (NOT a tsvector table)

  The `search` object in the doc's scope table is **not** a search engine.
  It is a **tokenized index convention**: a `SearchIndex` resource that acts as
  a catalog of which (non-PII) columns on which resources are indexed into a
  Postgres `tsvector` column. The physical tsvector lives on the resource's own
  table (e.g. `pfl_file.pfl_search_vector tsvector`). This resource is the
  registry and config surface.

  ### Red path: no PII column in search index

  A PII-declared column (vault-routed via `pii do`) CANNOT be listed as a
  searchable field. The verifier gate (`SearchIndex.assert_no_pii_column/1`)
  fails closed if a host registers a vaulted column as a search field.

  ## Audit rides T2.2 — never duplicated

  The scope table lists `audit` under Primitives. This is the existing
  append-only `aud_event` tier. Primitives actions that must be audited
  (webhook registered, feature flag toggled, file uploaded) call
  `Samen.AuditEvent.insert/2`. See `Samen.Scopes.Primitives.Audit`.

  ## Webhook🔒 — HMAC signing secret encrypted

  The `webhook🔒` resource stores the per-endpoint HMAC signing secret as a
  vault-routed PII field. This prevents the secret from appearing in logs,
  spans, CDC, or rollups. The actual HMAC computation is in
  `Samen.Scopes.Primitives.WebhookSigner` and reads the secret only inside
  the declared reveal context.

  ## Feature flag — Tier-0 config rows

  `feature_flag` is the Tier-0 config resource for this scope: one row per
  named flag per org (or global, org_id nil). Org-scoped reads; admin-gated
  writes. The flag's `enabled` boolean controls the feature gate.

  ## Mounting Primitives (the host side)

      defmodule Demo.PrimitivesScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Primitives,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.PrimitivesScope
      end

  This defines, in the host's namespace:

    * `Demo.PrimitivesScope.Notification` — 🔒 (rendered_body vault-routed)
    * `Demo.PrimitivesScope.File`         — file record (no PII; path + metadata)
    * `Demo.PrimitivesScope.SearchIndex`  — tsvector index registry (no PII columns)
    * `Demo.PrimitivesScope.Webhook`      — 🔒 (signing_secret vault-routed); Tier-0 config
    * `Demo.PrimitivesScope.FeatureFlag`  — Tier-0 config rows (no PII)

  Audit is a writers-only module (`Samen.Scopes.Primitives.Audit`) — no resource.

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name:

    * `Demo.PrimitivesScope.Notification` → `pnt`
    * `Demo.PrimitivesScope.NotificationPreference` → `npr`
    * `Demo.PrimitivesScope.File`         → `pfl`
    * `Demo.PrimitivesScope.SearchIndex`  → `psh`
    * `Demo.PrimitivesScope.Webhook`      → `pwh`
    * `Demo.PrimitivesScope.FeatureFlag`  → `pff`

  The macro does NOT invent abbrevs. Defaults are provided for the demo mount.
  """

  @default_abbrevs %{
    notification: "pnt",
    notification_preference: "npr",
    file: "pfl",
    search_index: "psh",
    webhook: "pwh",
    feature_flag: "pff"
  }

  @doc false
  def default_abbrevs, do: @default_abbrevs

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    # Resolve abbrevs to a plain %{atom => string} map AT EXPANSION TIME so each
    # blueprint call receives a LITERAL abbrev string.
    abbrevs = resolve_abbrevs(Keyword.get(opts, :abbrevs), __CALLER__)

    notification_mod = Module.concat(namespace, Notification)
    notification_preference_mod = Module.concat(namespace, NotificationPreference)
    file_mod = Module.concat(namespace, File)
    search_index_mod = Module.concat(namespace, SearchIndex)
    webhook_mod = Module.concat(namespace, Webhook)
    feature_flag_mod = Module.concat(namespace, FeatureFlag)

    quote do
      require Samen.Scopes.Primitives.Blueprint

      # Register the Primitives resources in the host domain.
      resources do
        resource(unquote(notification_mod))
        resource(unquote(notification_preference_mod))
        resource(unquote(file_mod))
        resource(unquote(search_index_mod))
        resource(unquote(webhook_mod))
        resource(unquote(feature_flag_mod))
      end

      # Materialize resource modules in the host namespace.
      Samen.Scopes.Primitives.Blueprint.define_notification(
        unquote(notification_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.notification)
      )

      Samen.Scopes.Primitives.Blueprint.define_notification_preference(
        unquote(notification_preference_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.notification_preference)
      )

      Samen.Scopes.Primitives.Blueprint.define_file(
        unquote(file_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.file)
      )

      Samen.Scopes.Primitives.Blueprint.define_search_index(
        unquote(search_index_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.search_index)
      )

      Samen.Scopes.Primitives.Blueprint.define_webhook(
        unquote(webhook_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.webhook)
      )

      Samen.Scopes.Primitives.Blueprint.define_feature_flag(
        unquote(feature_flag_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.feature_flag)
      )
    end
  end

  # Resolve the abbrev override (an AST map literal or nil) to a plain
  # %{atom => string} map, merged over the defaults.
  defp resolve_abbrevs(nil, _caller), do: @default_abbrevs

  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    override =
      Map.new(pairs, fn {k, v} ->
        {Macro.expand(k, caller), Macro.expand(v, caller)}
      end)

    Map.merge(@default_abbrevs, override)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Primitives, abbrevs: must be a compile-time map literal " <>
            "(%{notification: \"abc\", ...}). Got: #{Macro.to_string(other)}"
  end
end
