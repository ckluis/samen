defmodule Samen.Fleet.Scope.Blueprint do
  @moduledoc """
  Resource-definition macros for the **fleet registry** (ADR-044 §4.1, WS-J J1) — the
  five `flt_*` resources every fleet COCKPIT mounts: `App · Credential ·
  EnrollmentToken · Report · Directive`.

  Every resource is `use Samen.Aggregate.Resource` (not `Samen.Resource` directly),
  so the C7 `Samen.Verifiers.NoPiiColumns` compile check runs on each — a
  `pii_attribute`, a `vault` block, a `pii_`-shaped column, or a relationship
  reaching a PII-bearing resource fails the build (INV-2 by construction). None of
  the five carries a tenant identifier: `flt_report.payload` carries only
  `Samen.Fleet.Report.Schema`-shaped data (validated at ingest, never a tenant name),
  and `flt_credential`'s `secret_ciphertext` is a KMS-WRAPPED blob (opaque bytes, not
  PII by any reading).

  Like `Demo.Aggregate.MrrByTier`, every resource declares `org_id` as an explicit
  NULLABLE override — the fleet registry is cross-tenant/operator-owned data, not a
  tenant-plane resource, so it opts OUT of the universal non-null `org_id` injection.

  ## Policies

  Reads are admitted by `Samen.Policy.AggregateActorOnly` (the same singleton
  actor `Samen.Fleet.Report.build/1`/T84's cockpit reads use) OR
  `Samen.Policy.FleetAdminOnly`. Admin-gated writes (register/deregister an app,
  issue/revoke a credential, mint a token, record a directive) are admitted by
  `Samen.Policy.FleetAdminOnly` alone. `flt_report` creates are ALSO admitted by
  `Samen.Policy.FleetIngressOnly` (the heartbeat actor's one write). The
  token-consuming enroll transaction and the initial mode-B `flt_app`/`flt_credential`
  rows it creates run with `authorize?: false` (ADR-035 §4.2 pattern —
  `Samen.Auth.TokenConsume`/`Samen.Identity.Register`: the atomic single-use token
  match IS the authorization event; there is no actor yet to check a policy against).
  """

  # ---------------------------------------------------------------------------
  # flt_app — one registered product (§4.1)
  # ---------------------------------------------------------------------------
  defmacro define_app(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        `flt_app` — one registered product (ADR-044 §4.1). `slug` is
        cockpit-side/operator-typed ONLY (§5.2: never read from an enroll request or
        a report). `display_name` is operator-authored (mode A) or read from the
        consumed enrollment token (mode B) or, in `:embedded` mode, the host's own
        compile-time OTP application name — never runtime producer-chosen text.
        """
        use Samen.Aggregate.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_app")
          repo(unquote(repo))
        end

        attributes do
          attribute(:org_id, :uuid, public?: true, allow_nil?: true)

          attribute(:slug, :string, public?: true, allow_nil?: false)
          attribute(:display_name, :string, public?: true, allow_nil?: false)

          attribute(:mode, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:embedded, :manual, :heartbeat]]
          )

          # mode A only.
          attribute(:base_url, :string, public?: true)

          attribute(:status, :atom,
            public?: true,
            allow_nil?: false,
            default: :active,
            constraints: [one_of: [:active, :suspended, :deregistered]]
          )

          attribute(:registered_at, :utc_datetime_usec, public?: true, allow_nil?: false)
          attribute(:stale_after_s, :integer, public?: true, allow_nil?: false, default: 300)
        end

        actions do
          defaults([:read, create: :*, update: :*])
        end

        policies do
          policy action_type([:create, :update, :destroy]) do
            authorize_if(Samen.Policy.FleetAdminOnly)
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.AggregateActorOnly)
            authorize_if(Samen.Policy.FleetAdminOnly)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # flt_credential — one key version (§4.1, §4.5)
  # ---------------------------------------------------------------------------
  defmacro define_credential(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        `flt_credential` — one key version for one app (ADR-044 §4.1/§4.5).
        `secret_ciphertext` (mode A) is ALWAYS the KMS-wrapped ciphertext — never a
        plaintext column (INV-2/ADR-001). `public_key` (mode B) is public by
        construction, safe at rest. Deny-on-use is `revoked_at IS NULL AND
        (retire_at IS NULL OR retire_at > now())`, re-checked per request (RP-J-3 —
        the sabotage target: dropping the `revoked_at` clause from a lookup).
        """
        use Samen.Aggregate.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_credential")
          repo(unquote(repo))
        end

        attributes do
          attribute(:org_id, :uuid, public?: true, allow_nil?: true)

          attribute(:app_id, :uuid, public?: true, allow_nil?: false)
          attribute(:key_version, :integer, public?: true, allow_nil?: false, default: 1)

          attribute(:kind, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:shared_secret, :ed25519]]
          )

          # mode B only — base64, PUBLIC, safe at rest.
          attribute(:public_key, :string, public?: true)

          # mode A only — the KMS-wrapped ciphertext, base64-encoded. NEVER plaintext.
          attribute(:secret_ciphertext, :string, public?: true)

          attribute(:capability, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:fleet_heartbeat, :fleet_probe]]
          )

          attribute(:activated_at, :utc_datetime_usec, public?: true, allow_nil?: false)
          attribute(:retire_at, :utc_datetime_usec, public?: true)
          attribute(:revoked_at, :utc_datetime_usec, public?: true)
        end

        actions do
          defaults([:read, create: :*, update: :*])
        end

        policies do
          policy action_type([:create, :update, :destroy]) do
            authorize_if(Samen.Policy.FleetAdminOnly)
          end

          policy action_type(:read) do
            # Deliberately NOT admitted for Samen.Policy.FleetIngressOnly — the
            # heartbeat actor's whole point is ZERO read (ADR §4.6/RP-J-2). Only the
            # aggregate actor (T84 cockpit reads) or a fleet admin may read this table.
            authorize_if(Samen.Policy.AggregateActorOnly)
            authorize_if(Samen.Policy.FleetAdminOnly)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # flt_enrollment_token — a single-use enrollment grant (§4.1/§4.3, ADR-035 §4.2)
  # ---------------------------------------------------------------------------
  defmacro define_enrollment_token(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        `flt_enrollment_token` — a single-use mode-B enrollment grant (ADR-044 §4.3),
        the ADR-035 §4.2 discipline verbatim: 32 random bytes, ONLY the SHA-256 digest
        persisted, 24h expiry, atomic single-use consume
        (`Samen.Fleet.Registry.consume_enrollment/2` mirrors
        `Samen.Auth.TokenConsume.consume_once/3`'s one-statement UPDATE ... WHERE
        token_digest = $1 AND consumed_at IS NULL AND expires_at > now() RETURNING).
        `app_slug`/`display_name` are OPERATOR-TYPED at issuance and are the
        AUTHORITATIVE identity for the enrolling app — never overridden by anything
        the enroll request body claims (§4.3, §5.2).
        """
        use Samen.Aggregate.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_enrollment_token")
          repo(unquote(repo))
        end

        attributes do
          attribute(:org_id, :uuid, public?: true, allow_nil?: true)

          attribute(:token_digest, :string, public?: true, allow_nil?: false)
          attribute(:app_slug, :string, public?: true, allow_nil?: false)
          attribute(:display_name, :string, public?: true, allow_nil?: false)
          attribute(:expires_at, :utc_datetime_usec, public?: true, allow_nil?: false)
          attribute(:consumed_at, :utc_datetime_usec, public?: true)
          attribute(:consumed_app_id, :uuid, public?: true)
        end

        actions do
          defaults([:read, create: :*])

          update :consume do
            accept([])
            argument(:consumed_at, :utc_datetime_usec, allow_nil?: false)
            change(set_attribute(:consumed_at, arg(:consumed_at)))
            require_atomic?(false)
          end

          # A best-effort AUDIT backfill, called once the enrolled app's
          # cockpit-assigned id is known (the id cannot be known atomically at
          # consume time — Ash generates it on the App create that immediately
          # follows). Never security-relevant: identity/authorization already
          # happened at `:consume` (the atomic single-use token match).
          update :record_consumed_app do
            accept([:consumed_app_id])
            require_atomic?(false)
          end
        end

        policies do
          policy action_type([:create]) do
            authorize_if(Samen.Policy.FleetAdminOnly)
          end

          policy action(:record_consumed_app) do
            authorize_if(always())
          end

          policy action(:consume) do
            # The atomic digest+unconsumed+unexpired WHERE match IS the authorization
            # (ADR-035 §4.2 pattern) — this action is always called with
            # `authorize?: false` by Samen.Fleet.Registry.consume_enrollment/2.
            authorize_if(always())
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.FleetAdminOnly)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # flt_report — the latest report per app + bounded history (§4.1)
  # ---------------------------------------------------------------------------
  defmacro define_report(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        `flt_report` — one received `FleetReport` (ADR-044 §4.1). `payload` is
        schema-validated against `Samen.Fleet.Report.Schema` BEFORE this action is
        ever called (`Samen.Fleet.Registry.record_report/3` — a non-conforming
        payload is rejected `422` and never reaches this table, §5.2 point 4).
        `received_at` (COCKPIT clock) — never the producer's `generated_at_us` — is
        what staleness is computed from (ADR §4.6/§8.2 rule 3).
        """
        use Samen.Aggregate.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_report")
          repo(unquote(repo))
        end

        attributes do
          attribute(:org_id, :uuid, public?: true, allow_nil?: true)

          attribute(:app_id, :uuid, public?: true, allow_nil?: false)
          attribute(:schema_version, :integer, public?: true, allow_nil?: false, default: 1)
          attribute(:generated_at_us, :integer, public?: true, allow_nil?: false)
          attribute(:received_at, :utc_datetime_usec, public?: true, allow_nil?: false)

          attribute(:transport, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: [:embedded, :pull, :push]]
          )

          attribute(:payload, :map, public?: true, allow_nil?: false, default: %{})
        end

        actions do
          defaults([:read, create: :*])
        end

        policies do
          policy action_type(:create) do
            authorize_if(Samen.Policy.FleetAdminOnly)
            authorize_if(Samen.Policy.FleetIngressOnly)
          end

          # ADR-044 §4.6 capability matrix: "valid heartbeat key, other app_id in
          # body ⇒ 403; own app_id ⇒ 204". A SEPARATE (ANDed) block so it composes
          # with — never replaces — the block above; `FleetOwnAppOnly` is a
          # pass-through (expr(true)) for any non-heartbeat actor (fleet-admin's
          # write path is unrestricted by this dimension), so it narrows ONLY the
          # heartbeat actor's own capability.
          policy action_type(:create) do
            authorize_if(Samen.Policy.FleetOwnAppOnly)
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.AggregateActorOnly)
            authorize_if(Samen.Policy.FleetAdminOnly)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # flt_directive — a published fleet directive (§4.1) — registry storage only;
  # the precedence-composition/fan-out ENGINE is T84 (ADR §7, J4).
  # ---------------------------------------------------------------------------
  defmacro define_directive(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        `flt_directive` — one published fleet directive (ADR-044 §4.1). Registry
        storage only: `fleet_revision` (monotonic), `target`, `payload` (the
        `FleetDirective` envelope, §7.2 — NOT bound by the report wire's four-class
        discipline; free text is the point there). Applying a directive to a local
        flag engine (precedence composition, §7.3) is **T84's** (ADR §7, J4) — this
        resource only records what the cockpit published.
        """
        use Samen.Aggregate.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_directive")
          repo(unquote(repo))
        end

        attributes do
          attribute(:org_id, :uuid, public?: true, allow_nil?: true)

          attribute(:fleet_revision, :integer, public?: true, allow_nil?: false)
          attribute(:target, :map, public?: true, allow_nil?: false, default: %{})
          attribute(:payload, :map, public?: true, allow_nil?: false, default: %{})
          attribute(:published_by, :string, public?: true, allow_nil?: false)
          attribute(:published_at, :utc_datetime_usec, public?: true, allow_nil?: false)
        end

        actions do
          defaults([:read, create: :*])
        end

        policies do
          policy action_type(:create) do
            authorize_if(Samen.Policy.FleetAdminOnly)
          end

          policy action_type(:read) do
            authorize_if(Samen.Policy.AggregateActorOnly)
            authorize_if(Samen.Policy.FleetAdminOnly)
          end
        end
      end
    end
  end
end
