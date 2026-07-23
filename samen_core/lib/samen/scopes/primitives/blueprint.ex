defmodule Samen.Scopes.Primitives.Blueprint do
  @moduledoc """
  Resource-definition macros for the Primitives scope (T3.7; ADR-004 blueprint).

  Objects: `notification🔒 · file · search · audit · webhook🔒 · feature_flag`
  (doc §"The inherited 80%" scope table).

  ## PII map (🔒)

  | Resource     | Field          | Vault       | Column type                          |
  |--------------|----------------|-------------|--------------------------------------|
  | notification | rendered_body  | :pii_body   | scalar (column: pii_pnt_rendered_body)|
  | webhook      | signing_secret | :pii_secret | scalar (column: pii_pwh_signing_secret)|

  Both are scalar `pii_attribute`s (not composite types) — `rendered_body` is
  free-text rendered notification content that may contain PII (name, email, etc.);
  `signing_secret` is an HMAC credential that must not appear in logs/spans.

  **Which check catches a FORGOTTEN 🔒 on these fields — precisely.** Neither
  `rendered_body` nor `signing_secret` is in the C4 `pii_classify` name-token list
  (`ssn·dob·mrn·cdl·tax_id·email·phone·address·…`), so `pii_classify` does NOT flag a
  de-vault of either. The gate enforces vault *consequences* of a declaration that exists,
  not the *presence* of the `pii do` block. The authoritative red paths for a de-vaulted
  free-text field here are exactly two: (1) the `vault_declared_parity` verifier (C6, review
  fix F3.1), which reads the DB and fails closed on a leftover `pii_pnt_rendered_body` /
  `pii_pwh_signing_secret` column that no resource routes, and (2) this scope's
  `primitives_scope_vault_routing_test.exs`. Do not assume `pii_classify` guards these fields.

  ## Search — tokenized index convention

  `SearchIndex` is a registry resource: one row per (resource_name, field_name) pair
  that the host has indexed into a Postgres `tsvector`. The constraint is:

    * `field_name` MUST NOT be a PII-declared column (vault-routed via `pii do`).

  The red-path proof: `Samen.Scopes.Primitives.SearchIndex.assert_no_pii_column/1`
  raises if the registered field is vault-routed. The physical `tsvector` column lives
  on the resource's own table (e.g. on `pfl_file`, a `pfl_search_vector` generated
  column). The registry is the governance layer.

  ## Audit — rides T2.2, never a new table

  The scope-authoring guide §6 is explicit: "A scope never defines its own audit
  table." Primitives writes to `aud_event` via `Samen.AuditEvent.insert/2`. See
  `Samen.Scopes.Primitives.Audit`.

  ## Webhook🔒 — signing secret encrypted

  The HMAC signing secret is vault-routed so it never appears in:
    * application logs (no_plaintext_pii CI tier)
    * spans/traces (pii_reads verifier)
    * CDC / rollup / audit columns (aud_event token-only invariant)

  The actual HMAC computation in `Samen.Scopes.Primitives.WebhookSigner` reads the
  decrypted secret only inside a reveal context.

  ## Tier-0 config rows

  `Webhook` is a Tier-0 config resource (per-endpoint subscription row — org admins
  manage webhook endpoints without forking the product). `FeatureFlag` is the other
  Tier-0 resource: per-org (or global) feature gate rows.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>`. Scalar PII fields carry the `pii_` prefix
  (e.g. `pii_pnt_rendered_body`, `pii_pwh_signing_secret`). The public catalog sees
  only logical names.
  """

  # ---------------------------------------------------------------------------
  # Notification — 🔒 PII: rendered_body (vault :pii_body). Org-scoped.
  # Stores a dispatched notification and its vault-routed rendered content.
  # ---------------------------------------------------------------------------
  defmacro define_notification(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Primitives.Notification — a dispatched notification 🔒 (doc scope table
        `notification🔒`).

        `rendered_body` is vault-routed PII: rendered notification content that may
        contain the recipient's name, email, or other personal data. Stored encrypted;
        masked by default; plaintext only via the declared reveal action under a grant.

        The `recipient_id` is an opaque UUID reference to the user/entity being
        notified — NOT PII itself (bounded ID). The `channel` and `event_type` are
        bounded enums, safe to log and label.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_notification")
          repo(unquote(repo))
        end

        attributes do
          # Opaque ID for the recipient user/entity. NOT PII (bounded UUID).
          attribute(:recipient_id, :uuid, public?: true, allow_nil?: false)

          attribute(:channel, :atom,
            public?: true,
            allow_nil?: false,
            default: :in_app,
            constraints: [one_of: [:in_app, :email, :sms, :push, :webhook]]
          )

          # A namespaced event type (e.g. "invoice.created"). Bounded label.
          attribute(:event_type, :string, public?: true, allow_nil?: false)

          attribute(:status, :atom,
            public?: true,
            default: :pending,
            constraints: [one_of: [:pending, :sent, :delivered, :failed, :read]]
          )

          attribute(:sent_at, :utc_datetime, public?: true)
          attribute(:read_at, :utc_datetime, public?: true)
          # Opaque metadata map: counts, retry info. Bounded fields only (no raw PII).
          attribute(:metadata, :map, public?: true, default: %{})
        end

        pii do
          vault(:pii_body)
          # Scalar PII: the rendered notification body may contain the recipient's
          # name, email, etc. Column carries the pii_ prefix: pii_pnt_rendered_body.
          pii_attribute(:rendered_body, :string, vault: :pii_body)
          reveal(:reveal_notification)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_notification, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_notification,
                label: :rendered_body
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:reveal_notification) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # NotificationPreference — per-recipient dispatch preferences (no PII). Org-scoped.
  # One row per (recipient_id, event_type). The engine checks this BEFORE writing a
  # Notification record: a suppressed (in_app_enabled=false) event type creates NO
  # record — the red-path anti-tautology proof.
  # ---------------------------------------------------------------------------
  defmacro define_notification_preference(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Primitives.NotificationPreference — per-recipient, per-event dispatch
        preference (ADR-016 §2.3; WS-A design §2.3/§5).

        One row per `(recipient_id, event_type)` pair. The
        `Samen.Notifications.Engine` consults this BEFORE writing a `Notification`
        record: when `in_app_enabled` is `false` for the event type, the engine
        creates NO record and dispatches nothing (the suppressed-event red path).
        `email_enabled` gates the email channel (opt-in for digests).

        ## Digest cadence (C8, T30) — `digest_cadence` / `digest_timezone`

        A DIGEST preference is not naturally per-`event_type` (it batches
        UNREAD notifications across every type into one periodic email), so it
        rides a RESERVED sentinel row: `event_type == "__digest__"` — one extra
        row per recipient, not a new resource/abbrev (keeps the C8 schema
        change to two columns on an already-generated-per-mount resource,
        rather than a brand-new per-tenant Ash resource + registry
        allocation). `Samen.Notifications.Digest` is the sole reader/writer of
        that sentinel row; every OTHER `(recipient_id, event_type)` row is
        unaffected (both columns default identically everywhere, so an
        existing non-digest preference row is indistinguishable from before).

          * `digest_cadence` — `off | daily | weekly` (default `daily`, c11)
          * `digest_timezone` — an IANA tz database name (default `"Etc/UTC"`)
            — "timezone-aware from existing user prefs" (c11): THIS preference
            resource is samen's existing per-user prefs row; there is no
            separate `Identity.User` timezone field to thread through.
          * `digest_last_sent_at` — nilable UTC timestamp; the due-check
            watermark `Samen.Notifications.Digest` reads/advances so a cadence
            fires at most once per period (never re-derived from send history).

        ## No PII by construction

        Every column is a bounded ID, enum, boolean, or a map of bounded ints:

          * `recipient_id` — opaque UUID (bounded reference, NOT subject PII)
          * `event_type`   — bounded namespaced label (e.g. `"invoice.created"`,
            or the reserved `"__digest__"` sentinel)
          * `in_app_enabled` / `email_enabled` — booleans (safe metrics)
          * `quiet_hours`   — a map of bounded ints (`%{start: 22, end: 7}`) — no
            free-text, no subject data
          * `digest_cadence` — bounded enum (`off | daily | weekly`)
          * `digest_timezone` — an IANA tz name (bounded catalog string, not PII)

        There is no `pii do` block: the resource carries no vault-routed field. This
        is the "bounded id + enums + bools" row in the WS-A data-model table.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_notification_preference")
          repo(unquote(repo))
        end

        attributes do
          # Opaque ID for the recipient user/entity. NOT PII (bounded UUID).
          attribute(:recipient_id, :uuid, public?: true, allow_nil?: false)

          # The namespaced event type this preference governs (e.g. "invoice.created").
          # Bounded label — not subject PII.
          attribute(:event_type, :string, public?: true, allow_nil?: false)

          # In-app dispatch gate. Default-ON: notifications appear in the inbox
          # unless the recipient explicitly opts out for this event type.
          attribute(:in_app_enabled, :boolean, public?: true, default: true)

          # Email dispatch gate. Default-OFF (opt-in for email/digests per §2.3).
          attribute(:email_enabled, :boolean, public?: true, default: false)

          # Quiet-hours window as bounded ints (e.g. %{"start" => 22, "end" => 7}).
          # No free-text; the scheduler that honors this is a fast-follow (§2.6).
          attribute(:quiet_hours, :map, public?: true, default: %{})

          # C8/T30 digest cadence — read on the RESERVED event_type == "__digest__"
          # sentinel row only (see moduledoc). Default :daily (c11).
          attribute(:digest_cadence, :atom,
            public?: true,
            default: :daily,
            constraints: [one_of: [:off, :daily, :weekly]]
          )

          # C8/T30 — IANA tz name (e.g. "America/New_York"). Default UTC.
          attribute(:digest_timezone, :string, public?: true, default: "Etc/UTC")

          # C8/T30 — the due-check watermark (nilable; nil = never sent).
          attribute(:digest_last_sent_at, :utc_datetime, public?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # A recipient manages their own preferences (member+); org-scoped.
          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # File — file record (no PII). Org-scoped.
  # Stores metadata + an opaque storage reference. The file content lives in
  # object storage (external); this is the governed catalog row.
  # ---------------------------------------------------------------------------
  defmacro define_file(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Primitives.File — a file metadata record (doc scope table `file`).

        Stores governance metadata about an uploaded file: an opaque `storage_key`
        (never rendered publicly), bounded `content_type`/`status` enums, and a
        `search_vector` tsvector column for full-text search over non-PII fields
        (`filename` and `content_type`).

        No PII: filename is a file system name (not a personal identifier in the
        doc's sense — not flagged 🔒). If a host's filenames ARE PII (e.g. a medical
        scan named after the patient), the host must vault them via a bounded-context
        override. The base resource does not vault filename.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_file")
          repo(unquote(repo))
        end

        attributes do
          # Human-readable filename — NOT PII in this base resource.
          attribute(:filename, :string, public?: true, allow_nil?: false)

          # MIME content type. Bounded string (safe to label/log).
          attribute(:content_type, :string, public?: true)

          # File size in bytes. Safe metric.
          attribute(:size_bytes, :integer, public?: true)

          # Opaque storage backend key (used internally by the host's storage adapter).
          # NOT PII — it is a system reference, not subject identity data.
          # public?: true so the default create action accepts it; the catalog/verifiers
          # cover it once registered.
          attribute(:storage_key, :string, public?: true, allow_nil?: false)

          # Quarantine-by-default is fail-CLOSED (ADR-026 §2, decision 3): a freshly
          # uploaded file is HELD, not trusted. The framework never asserts a file is
          # clean it has not scanned — the honest default posture is `:quarantined`
          # (not previewable/downloadable) until a `Samen.Files.Scanner` promotes it.
          # Flipping this back to `:active` FAILS the fail-closed red-path (RP-FI-3).
          attribute(:status, :atom,
            public?: true,
            default: :quarantined,
            constraints: [one_of: [:active, :archived, :deleted, :quarantined]]
          )

          # Opaque reference to the creating actor. Bounded ID.
          attribute(:uploaded_by_id, :uuid, public?: true)

          # Opaque metadata for integration-specific fields.
          attribute(:metadata, :map, public?: true, default: %{})

          # Tsvector search index — only non-PII columns (filename + content_type).
          # The search convention: this column is populated via a DB-level trigger or
          # UPDATE after insert; the SearchIndex registry governs what fields feed it.
          # See §"Search — tokenized index convention" in the scope moduledoc.
          attribute(:search_vector, :string, public?: false)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        # ADR-026 §2 decision 2 / RP-FI-1 / AC-G14-2 — governed-by-construction. The
        # public default `:create` AND `:update` both accept `storage_key` (`public?: true`),
        # so WITHOUT this guard a direct `Ash.create` could mint — or a direct `Ash.update`
        # could REPOINT — a `storage_key`-bearing row that skips size/type enforcement + the
        # `file.uploaded` audit — an ungoverned file row. A create-only guard left an
        # update-shaped hole (create a governed row, then `Ash.update` its `storage_key` to
        # an arbitrary key). Registering on BOTH `:create` and `:update` makes the "no
        # ungoverned file row" guarantee STRUCTURAL on every write: a create/update that
        # sets/repoints a `storage_key` is REFUSED unless it came through
        # `Samen.Files.upload/3` (which stamps the private chokepoint marker). Sabotaging
        # the chokepoint — or narrowing this back to `on: [:create]` — FAILS RP-FI-1.
        changes do
          change(Samen.Files.ChokepointGuard, on: [:create, :update])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # SearchIndex — tokenized index convention registry. Org-scoped. No PII.
  # One row per (resource_name, field_name) pair the host has indexed via tsvector.
  # CONSTRAINT: field_name MUST NOT be a PII-declared column.
  # ---------------------------------------------------------------------------
  defmacro define_search_index(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Primitives.SearchIndex — the tokenized index convention registry (doc scope
        table `search`).

        Each row declares that a specific (resource_name, field_name) is indexed into
        a Postgres `tsvector` column on the resource's table. This is the governance
        layer for search: it is not a search engine, it is a catalog of what has been
        indexed and under what conditions.

        ## The PII constraint

        A PII-declared column (vault-routed via `pii do`) MUST NOT be registered as a
        search field. Vault-routed columns hold encrypted ciphertext tokens — indexing
        them into a tsvector would index ciphertext, not plaintext, making the search
        useless; and it would create an untokenized path to a vaulted column (the
        verifier's pii_reads check would flag it). The constraint is enforced by:

          1. A runtime guard: `assert_no_pii_column/2` (called at register time).
          2. A test red path: `primitives_scope_search_pii_red_path_test.exs`.

        ## Search over non-PII columns only

        Only columns NOT declared as `pii_attribute` may be registered. The demo uses
        `file.filename` and `file.content_type` — both are plain string attributes.

        ## tsvector convention

        The physical tsvector column (e.g. `pfl_file.pfl_search_vector`) is a plain
        `:string` attribute on the resource, populated by the host's DB trigger or
        migration. This registry row maps the logical field name to the tsvector index.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_search_index")
          repo(unquote(repo))
        end

        attributes do
          # The fully-qualified resource module name (e.g. "Demo.PrimitivesScope.File").
          attribute(:resource_name, :string, public?: true, allow_nil?: false)

          # The logical field name on the resource (e.g. "filename").
          # CONSTRAINT: must NOT be a PII-declared column (enforced by assert_no_pii_column/2).
          attribute(:field_name, :string, public?: true, allow_nil?: false)

          # The tsvector column name on the resource's physical table (e.g. "pfl_search_vector").
          attribute(:vector_column, :string, public?: true, allow_nil?: false)

          # Human-readable description of this index entry.
          attribute(:description, :string, public?: true)

          attribute(:enabled, :boolean, public?: true, default: true)

          # The Postgres ts_config for the tsvector (e.g. "english").
          attribute(:ts_config, :string, public?: true, default: "english")
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Webhook — 🔒 PII: signing_secret (vault :pii_secret). Tier-0 config rows.
  # One row per webhook endpoint subscription per org. HMAC signing secret encrypted.
  # ---------------------------------------------------------------------------
  defmacro define_webhook(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Primitives.Webhook — a webhook endpoint subscription 🔒 (doc scope table
        `webhook🔒`).

        `signing_secret` is vault-routed PII: the HMAC signing secret for this
        endpoint (must not appear in logs, spans, CDC, or rollup columns). Stored
        encrypted; masked by default; plaintext only via the declared reveal action
        under a grant.

        This is also a **Tier-0 config resource**: org admins register webhook
        endpoints (URL + event subscription) without forking the product. The host's
        webhook delivery machinery (T3.13 scope or Oban job) looks up the endpoint
        URL + decrypts the signing secret at delivery time.

        ## Webhook delivery (doc §external-surface)

        Outbound events are Oban-backed: at-least-once, capped exponential backoff,
        DLQ, per-event idempotency keys, HMAC body + timestamp signing (anti-replay).
        The `status` tracks delivery posture (`:active`, `:paused`, `:failed`).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_webhook")
          repo(unquote(repo))
        end

        attributes do
          # The endpoint URL to deliver events to. NOT PII — it is a system address.
          attribute(:url, :string, public?: true, allow_nil?: false)

          # A human-readable label for this endpoint. NOT PII.
          attribute(:label, :string, public?: true)

          # Event types subscribed to (e.g. ["invoice.created", "user.updated"]).
          attribute(:event_types, {:array, :string}, public?: true, default: [])

          attribute(:status, :atom,
            public?: true,
            default: :active,
            constraints: [one_of: [:active, :paused, :failed, :deleted]]
          )

          # Delivery posture counters. Bounded integers — safe to log.
          attribute(:failure_count, :integer, public?: true, default: 0)
          attribute(:last_delivered_at, :utc_datetime, public?: true)

          # Opaque metadata for integration-specific fields.
          attribute(:metadata, :map, public?: true, default: %{})
        end

        pii do
          vault(:pii_secret)
          # Scalar PII: the HMAC signing secret. Column: pii_pwh_signing_secret.
          # This is a per-endpoint credential — must not appear in logs/spans/CDC.
          pii_attribute(:signing_secret, :string, vault: :pii_secret)
          reveal(:reveal_webhook)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_webhook, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_webhook,
                label: :signing_secret
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        policies do
          # Only admins+ may manage webhook endpoints (Tier-0 config-row convention).
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          policy action(:reveal_webhook) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # FeatureFlag — Tier-0 config rows (no PII). Org-scoped.
  # One row per named flag per org (or global). Admin-gated writes.
  # ---------------------------------------------------------------------------
  defmacro define_feature_flag(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Primitives.FeatureFlag — Tier-0 config rows for feature flags (doc scope table
        `feature_flag`).

        One row per named flag per org. The flag's `enabled` boolean controls the
        feature gate. Org admins toggle flags without forking the product (the bottom
        rung of the malleability ladder — config rows). No PII.

        Global flags (org_id nil / system-level) are an operator-plane concern handled
        outside the tenant policy. The base resource is org-scoped for tenant-plane
        use; system-level flags use `authorize?: false` in operator contexts.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_feature_flag")
          repo(unquote(repo))
        end

        attributes do
          # The flag name — a namespaced identifier (e.g. "billing.invoice_pdf").
          attribute(:name, :string, public?: true, allow_nil?: false)

          # Human-readable description. NOT PII.
          attribute(:description, :string, public?: true)

          # The gate value. Bounded boolean (safe to log as a metric).
          attribute(:enabled, :boolean, public?: true, default: false)

          # Rollout percentage (0-100). For gradual rollout config.
          attribute(:rollout_pct, :integer, public?: true, default: 100)

          # Bounded lifecycle state.
          attribute(:stage, :atom,
            public?: true,
            default: :beta,
            constraints: [one_of: [:beta, :ga, :deprecated, :archived]]
          )

          # Targeting rules (bounded jsonb list). Each rule keys ONLY off governed
          # NON-PII attributes (org_id, plan, tier, stage, role, region) — a rule
          # keyed on a PII-classified attribute is REFUSED at write by the
          # NonPiiTargeting validation (ADR-020 §2 decision 3; G6 RP-F3).
          attribute(:target_rules, {:array, :map}, public?: true, default: [])

          # Multivariate variants (bounded name→weight map) for the experiment seam
          # (ADR-020 §7 / design §3.4). Empty for a plain on/off flag.
          attribute(:variants, :map, public?: true, default: %{})

          # Opaque metadata for integration-specific flag config.
          attribute(:metadata, :map, public?: true, default: %{})
        end

        actions do
          defaults([:read, :destroy])

          create :create do
            primary?(true)
            accept(:*)
            # RP-F3: refuse a target rule keyed on a PII-classified attribute
            # (name/email/phone/…) at the WRITE boundary — by construction, a PII
            # subject key can NEVER reach evaluate/2.
            validate(Samen.FeatureFlags.NonPiiTargeting)
          end

          update :update do
            primary?(true)
            require_atomic?(false)
            accept(:*)
            validate(Samen.FeatureFlags.NonPiiTargeting)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Writes require admin+: config-row convention (guide §7).
          policy action_type([:create, :update, :destroy]) do
            forbid_unless(Samen.Policy.OrgScope)
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end
        end
      end
    end
  end
end
