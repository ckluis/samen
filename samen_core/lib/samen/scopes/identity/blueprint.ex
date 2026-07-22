defmodule Samen.Scopes.Identity.Blueprint do
  @moduledoc """
  The resource-definition macros for the Identity scope (ADR-004 blueprint).

  Each `define_*/N` macro emits a `defmodule` for a host-owned `use Samen.Resource`
  resource. The macros are called from `Samen.Scopes.Identity.__using__/1`, which
  passes the host's `otp_app`, `domain`, `repo`, and the resource's registered
  abbrev. Keeping the resource bodies here (not inline in the mount macro) makes each
  scope's shape reviewable in one place and gives the fan-out (T3.2–T3.7) a copyable
  template.

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage), injected by the Samen
  base macro. PII fields (`user.full_name`, `user.emails`, `invitation.email`) route
  through the vault via `pii_attribute` — composite types (`FullName`/`Emails`) route
  by vault name (no `pii_` prefix), scalars carry `pii_`. The public API/catalog only
  ever sees the logical name, never the storage name (doc §external-surface).

  ## Policies

  Every tenant-plane resource wires `Ash.Policy.Authorizer` and a `policies do` block
  with `Samen.Policy.OrgScope` (+ RBAC where relevant). `Org` is the org-less anchor
  and uses a membership-scoped policy instead of the plain org-scope filter.
  """

  # ---------------------------------------------------------------------------
  # T3.11 — allowlist serialization helpers.
  #
  # `api_extensions/1` returns the AshJsonApi.Resource extension list when the host
  # opted into the public API (`json_api: true`), else []. Fail-closed: if the flag
  # is set but ash_json_api is NOT compiled, raise — a mount misconfiguration must
  # not silently drop the public surface (nor silently publish it).
  #
  # `json_api_block/3` emits the `json_api do … end` block for a resource. It uses
  # `show_fields` — the LOAD-BEARING allowlist. `show_fields` is the schema-level
  # opt-in: a field NOT named here is absent from every payload, even via the
  # `?fields=` query param (AshJsonApi's serializer filters the final field set
  # through `show_field?`, which requires `field in show_fields`). This is exactly
  # the doc's "default not-exposed; a field absent from the allowlist is absent from
  # the payload by omission" — a newly added storage column never silently appears.
  #
  # The names in `show_fields` are the CATALOG field names (`:name`, `:full_name`),
  # NEVER storage names (`ido_name`, `pii_usr_dob`): AshJsonApi serializes by Ash
  # attribute name, and the abbrev storage column exists only in the postgres layer.
  @doc false
  def api_enabled!(false), do: false

  def api_enabled!(true) do
    if Code.ensure_loaded?(AshJsonApi.Resource) do
      true
    else
      raise """
      Samen.Scopes.Identity was mounted with `json_api: true` but AshJsonApi is not \
      compiled. The public /api/v1 surface is opt-in; add `{:ash_json_api, "~> 1.7"}` \
      to the host's deps (plan OD-6). Refusing to mount an Identity scope whose public \
      API silently disappears.
      """
    end
  end

  # ---------------------------------------------------------------------------
  # Org — the tenant anchor. Org-less (no org_id FK on itself). No PII.
  # ---------------------------------------------------------------------------
  defmacro define_org(module, otp_app, domain, repo, abbrev, json_api? \\ false) do
    api? = api_enabled!(json_api?)

    extensions =
      if api?, do: [AshJsonApi.Resource], else: []

    json_api_block =
      if api? do
        quote do
          json_api do
            type("org")

            # ALLOWLIST (opt-in, default not-exposed): only these catalog names are
            # published. `plan` is Tier-0 config; `slug`/`org_id` are NOT allowlisted
            # → absent from every payload by omission.
            show_fields([:id, :name, :plan])

            routes do
              base("/orgs")
              # Bounded-by-default API read (WS-A design §1.1, ADR-016 §3): keyset
              # pagination, default_limit 50 / max_page_size 200 — a no-page-param index
              # read returns a bounded page; an over-max page[limit] is clamped.
              get(:api_read)
              index(:api_read)
            end
          end
        end
      end

    quote do
      defmodule unquote(module) do
        @moduledoc "Identity.Org — the tenant anchor (doc scope table). No PII, org-less."
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: unquote(extensions),
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_org")
          repo(unquote(repo))
        end

        unquote(json_api_block)

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:slug, :string, public?: true)
          # Tier-0 config: plan is a bounded config value on the org row.
          attribute(:plan, :string, public?: true, default: "free")

          # ADR-035 §4.3/§5 A4 (spec-questions c3) — the OPTIONAL org-level concurrent-
          # session cap: nil = unlimited (the default). When set, `Samen.Auth.SessionCreate`
          # evicts the credential's OLDEST live session(s) at create time so the live count
          # never exceeds the cap. A credential can hold Memberships in several orgs (Session
          # itself is org-less — it authenticates the credential, before any one org is
          # chosen); the MOST RESTRICTIVE (smallest) non-nil cap across the credential's
          # orgs governs, the same "tightest wins" posture as any other cross-org policy
          # ceiling in this spine (mirrors the invite rank-ceiling precedent, §5 A5).
          attribute(:max_concurrent_sessions, :integer,
            public?: true,
            allow_nil?: true,
            constraints: [min: 1]
          )

          # ADR-035 §5 A8 (T08) — the onboarding-wizard COMPLETION marker: a Tier-0
          # org setting, nil until `Samen.Web.Onboarding.complete!/3` lands it. This
          # is what makes the wizard "never re-trap" (its own moduledoc): every
          # mount checks THIS column, never client-side/session state, so the
          # checklist cannot resurrect itself on a later visit once finished.
          attribute(:onboarded_at, :utc_datetime, public?: true, allow_nil?: true)

          # The org anchor is org-LESS: it IS the tenant boundary, so its own
          # `org_id` is meaningless. Declare it nullable here so `CoreAttributes`
          # does not inject a NOT-NULL `org_id` the anchor can never satisfy. The
          # `OrgIsSelf` policy scopes by `id`, not `org_id`.
          attribute(:org_id, :uuid, public?: true, allow_nil?: true)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # Bounded-by-default API read the JSON:API routes bind to (WS-A design §1.1,
          # ADR-016 §3). Distinct from `:read` so internal `Ash.read!` callers keep
          # getting a plain list; the API is bounded (keyset, default_limit 50, cap 200).
          read :api_read do
            pagination(
              keyset?: true,
              default_limit: 50,
              max_page_size: 200,
              required?: false,
              paginate_by_default?: true
            )
          end
        end

        # Org is the tenant boundary itself. An actor may read/write only the org
        # whose id matches their scope's org_id. Bootstrap (creating the first org)
        # is an operator-plane / unauthenticated-provisioning concern handled outside
        # the tenant policy: create is allowed (a new org has no members yet), read/
        # update/destroy require the actor be scoped to THIS org.
        policies do
          policy action_type(:create) do
            authorize_if(always())
          end

          policy action_type([:read, :update, :destroy]) do
            # The org row's own id must equal the actor's org_id (org anchor
            # self-scope). Named FilterCheck — an inline `expr(id == …)` here would
            # be hygiene-captured inside the blueprint's quote.
            authorize_if(Samen.Policy.OrgIsSelf)
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # User — 🔒 PII: full_name (vault :pii_name), emails (vault :pii_email).
  # Org-scoped. A user belongs to an org (the org_id core column).
  # ---------------------------------------------------------------------------
  defmacro define_user(module, otp_app, domain, repo, abbrev, json_api? \\ false) do
    api? = api_enabled!(json_api?)
    extensions = if api?, do: [AshJsonApi.Resource], else: []

    json_api_block =
      if api? do
        quote do
          json_api do
            type("user")

            # ALLOWLIST. `handle` and `status` are non-PII. `full_name` and `emails`
            # are vault-routed PII — allowlisted so they can appear (masked `••••` /
            # absent per plane), which is the whole two-key-classes proof. What marks
            # them PII is their vault routing (the `pii do`), NOT a `pii_` prefix.
            # NOT allowlisted → absent by omission: `org_id`, `inserted_at`, etc.
            show_fields([:id, :handle, :status, :full_name, :emails])

            routes do
              base("/users")
              # Bounded-by-default API read (WS-A design §1.1, ADR-016 §3).
              get(:api_read)
              index(:api_read)
            end
          end
        end
      end

    # T3.11 — the API PII-resolution rule on all reads (only when the API is mounted).
    # Inert for plane-less internal reads; on the API it clears own-org PII for a
    # tenant key and forbids (omits) vaulted fields for an operator key without a grant.
    api_preparations =
      if api? do
        quote do
          preparations do
            prepare(Samen.Api.PiiResolution)
          end
        end
      end

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.User — a user 🔒. `full_name` and `emails` are vault-routed PII
        (doc scope table `user🔒`). Org-scoped; masked by default.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: unquote(extensions),
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_user")
          repo(unquote(repo))
        end

        unquote(json_api_block)

        attributes do
          # A non-PII display handle (safe to log/label — like the CRM display_name).
          attribute(:handle, :string, public?: true)
          attribute(:status, :string, public?: true, default: "active")

          # ADR-035 §3.1 — additive, nullable FK to the org-less Credential (THE
          # authentication principal; one human, N orgs, N per-org Users). Nullable
          # so existing User rows created before the identity spine mounted (or by
          # a host still on BYO-auth/ADR-031) are unaffected — no migration break.
          attribute(:credential_id, :uuid, public?: false, allow_nil?: true)
        end

        pii do
          vault(:pii_name)
          vault(:pii_email)

          pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
          pii_attribute(:emails, Samen.Type.Emails, vault: :pii_email)

          reveal(:reveal_user)
        end

        unquote(api_preparations)

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # Bounded-by-default API read the JSON:API routes bind to (WS-A design §1.1,
          # ADR-016 §3). PII on `:api_read` resolves per plane via the resource-level
          # PiiResolution preparation, same as `:read`.
          read :api_read do
            pagination(
              keyset?: true,
              default_limit: 50,
              max_page_size: 200,
              required?: false,
              paginate_by_default?: true
            )
          end

          # The declared reveal action (operator-plane plaintext under a grant).
          action :reveal_user, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_user,
                label: :emails
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

          # The reveal action is generic (not a data read/write); its own grant gate
          # inside the run/2 is the real control. Allow it to run for any actor —
          # the grant check denies by default.
          policy action(:reveal_user) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Membership — (user, org, role). RBAC-gated: only admins+ may mutate; no
  # escalation above the actor's own rank. Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_membership(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             user_mod,
             _org_mod,
             json_api? \\ false
           ) do
    api? = api_enabled!(json_api?)
    extensions = if api?, do: [AshJsonApi.Resource], else: []

    json_api_block =
      if api? do
        quote do
          json_api do
            type("membership")
            # ALLOWLIST. `role`/`status` are bounded config; no PII on membership.
            show_fields([:id, :role, :status])

            routes do
              base("/memberships")
              # Bounded-by-default API read (WS-A design §1.1, ADR-016 §3).
              get(:api_read)
              index(:api_read)
            end
          end
        end
      end

    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.Membership — a (user, org, role) association (doc scope table
        `membership`). Carries the RBAC role. Org-scoped; RBAC-gated (only admins+
        may mutate, and never escalate above their own rank).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: unquote(extensions),
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_membership")
          repo(unquote(repo))
        end

        unquote(json_api_block)

        attributes do
          # The RBAC role. Bounded enum (Samen.Scope.Role). Default :member.
          attribute(:role, :atom,
            public?: true,
            default: :member,
            constraints: [one_of: Samen.Scope.Role.all()]
          )

          attribute(:status, :string, public?: true, default: "active")
        end

        relationships do
          belongs_to :user, unquote(user_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        # F3.5 same-org FK: a membership may only reference a same-org user.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:user]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # Bounded-by-default API read the JSON:API routes bind to (WS-A design §1.1,
          # ADR-016 §3). `action_type(:read)` policies below cover it.
          read :api_read do
            pagination(
              keyset?: true,
              default_limit: 50,
              max_page_size: 200,
              required?: false,
              paginate_by_default?: true
            )
          end
        end

        policies do
          # Every membership read/write is org-scoped.
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Writes additionally require admin+ AND no escalation above the actor's
          # own rank. Both must pass (forbid_unless = deny if either fails).
          policy action_type([:create, :update, :destroy]) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            forbid_unless(Samen.Policy.ManageRole)
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Role — Tier-0 config rows: the per-org catalog of role definitions. Org-scoped.
  # No PII. This is the "Tier-0 config-row convention" the guide documents.
  # ---------------------------------------------------------------------------
  defmacro define_role(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.Role — Tier-0 config rows (doc scope table `role`). One row per
        role name available in an org, with a bounded rank. Org-scoped; admin-gated
        writes. The RBAC *mechanism* is `Samen.Scope.Role`; these rows are the
        per-org config surface (rename a role label, disable a role) that the
        malleability ladder's bottom rung (config rows) allows.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_role")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: Samen.Scope.Role.all()]
          )

          attribute(:label, :string, public?: true)
          attribute(:rank, :integer, public?: true, allow_nil?: false)
          attribute(:enabled, :boolean, public?: true, default: true)
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
  # ApiKey — a scoped credential bound to a membership + plane. Org-scoped.
  # The "cannot out-reach its actor" rule is enforced at USE time by
  # Samen.Scope.ApiKey.authorized?/4 (the key's effective scope = ∩ its minter's
  # role). The row stores the declared scopes + plane + minter role.
  # ---------------------------------------------------------------------------
  defmacro define_api_key(module, otp_app, domain, repo, abbrev, membership_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.ApiKey — a scoped credential (doc scope table `api_key`; doc
        §external-surface "two key classes"). Bound to one plane
        (`:tenant`/`:operator`) and its minting membership. Its effective authority
        is `∩` the minter's role — a key can never out-reach its actor
        (`Samen.Scope.ApiKey.authorized?/4`).

        The `token_digest` column stores a hash of the key, never the key itself
        (the raw key is shown once at mint and never persisted in clear). It is a
        one-way digest — NOT PII, NOT vault-routed (it is a credential, not subject
        data), but also never rendered.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_api_key")
          repo(unquote(repo))
        end

        attributes do
          # SHA-256 digest of the key material. One-way; the raw key is never stored.
          attribute(:token_digest, :string, public?: false, allow_nil?: false)

          attribute(:plane, :atom,
            public?: true,
            allow_nil?: false,
            default: :tenant,
            constraints: [one_of: [:tenant, :operator]]
          )

          # Declared scopes as a bounded map: %{family => [:read,:write]}. The
          # effective authority is the intersection with the minter's role at use.
          attribute(:scopes, :map, public?: true, default: %{})

          # The role of the minting membership — the actor ceiling this key inherits.
          attribute(:minter_role, :atom,
            public?: true,
            constraints: [one_of: Samen.Scope.Role.all()]
          )

          attribute(:revoked_at, :utc_datetime, public?: true)

          # F3.4 — bounded expiry (deny-on-read). Every minted key carries a hard
          # time ceiling (`Samen.Scope.ApiKey.bounded_expiry/2`); the auth lookup
          # filters `expires_at > now` so an expired row is never resolved to an
          # actor. `nil` is a legacy pre-gate row (non-expiring predicate); the
          # minter never produces one.
          attribute(:expires_at, :utc_datetime, public?: true)

          # F3.4 — last-use observability. Best-effort stamped by the auth path on a
          # successful resolve; supports stale-key hygiene reporting. Never gates auth.
          attribute(:last_used_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :membership, unquote(membership_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        # F3.5 same-org FK: an api_key may only reference a same-org membership.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:membership]})
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # F3.4 — least-privilege touch action: the auth path stamps ONLY
          # `last_used_at` (never expiry/scopes/plane), best-effort, authorize?: false.
          # Non-atomic: the inherited SameOrgFk change can't run atomically (it reads
          # the related row); this touch is best-effort off the hot path regardless.
          update :mark_used do
            accept([:last_used_at])
            require_atomic?(false)
          end
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Only admins+ may mint or revoke keys; and org-scoped.
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
  # Invitation — 🔒 PII: email (vault :pii_email). Org-scoped. A pending invite.
  #
  # ADR-035 §5 A5 (T05 hardening): `accept_token` (plaintext-shaped, ApiKey
  # `token_digest` precedent NOT yet applied) is REPLACED by `token_digest`
  # (SHA-256 digest at rest, §4.2) + `email_bidx` (the §4.1 non-reversible
  # keyed-HMAC lookup — "invite-matching" is one of §4.1's named consumers, so
  # accept-time credential matching never needs a vault reveal). `expires_at`
  # is the 14-day invite-context row (§4.2 table); `accepted_at`/`revoked_at`
  # are the terminal-state timestamps for the 4-state lifecycle `pending ->
  # accepted | revoked | expired`.
  # ---------------------------------------------------------------------------
  defmacro define_invitation(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.Invitation — a pending org invitation 🔒 (doc scope table
        `invitation🔒`). The invitee `email` is vault-routed PII (masked by default;
        plaintext only via the declared reveal action under a grant). Org-scoped.

        Lifecycle (ADR-035 §5 A5): `pending -> accepted | revoked | expired`.
        The transition guard lives in the QUERY `Samen.Identity.Invite` runs
        (the `Samen.Auth.TokenConsume` discipline — WHERE `status == "pending"`
        AND `expires_at > now()`, a single atomic UPDATE), not in these bare
        `:accept`/`:revoke`/`:expire` actions themselves: an illegal transition
        (e.g. accepting an already-`accepted`/`revoked`/`expired` row) simply
        matches ZERO rows and is refused. `:accept`/`:expire` are reachable
        ONLY through `Samen.Identity.Invite`'s governed internal calls
        (`authorize?: false` — same posture as `AuthToken`'s `:consume`);
        `:revoke` is an admin-gated cancel (org-scoped + `RoleAtLeast(:admin)`).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_invitation")
          repo(unquote(repo))
        end

        attributes do
          attribute(:role, :atom,
            public?: true,
            default: :member,
            constraints: [one_of: Samen.Scope.Role.all()]
          )

          attribute(:status, :string, public?: true, default: "pending")

          # Credential-class columns (ApiKey `token_digest` precedent) —
          # `public?: false`, never allowlisted, set ONLY via
          # `force_change_attribute` from `Samen.Identity.Invite` (never a
          # public create/update input).
          attribute(:token_digest, :string, public?: false)

          # ADR-035 §4.1 — the non-reversible keyed-HMAC lookup index binding
          # the invite to the address it was sent to. Accept-time credential
          # matching reads THIS, never the vault (no reveal at accept).
          attribute(:email_bidx, :string, public?: false)

          attribute(:expires_at, :utc_datetime, public?: false)
          attribute(:accepted_at, :utc_datetime, public?: false, allow_nil?: true)
          attribute(:revoked_at, :utc_datetime, public?: false, allow_nil?: true)
        end

        pii do
          vault(:pii_email)
          pii_attribute(:email, Samen.Type.Emails, vault: :pii_email)
          reveal(:reveal_invitation)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_invitation, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_invitation,
                label: :email
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end

          # ADR-035 §5 A5 — the ONE atomic single-use `pending -> accepted`
          # transition (mirrors `AuthToken.:consume`'s discipline — see the
          # moduledoc). Called ONLY through `Samen.Identity.Invite.accept/3`,
          # which scopes the QUERY to `status == "pending" and expires_at >
          # now`, forced `strategy: [:atomic]` — a replayed/expired/revoked
          # token matches zero rows.
          # `require_atomic? false`: the resource-wide `Samen.Pii.WriteGuard`/
          # `Samen.Vault.Change` pair (injected for EVERY create/update by
          # `MaterializePii` because `email` is a pii_attribute) cannot be
          # statically proven atomic-compatible by the DSL verifier — even
          # though neither ever touches `:email` here (`accept []`, only
          # `:status`/timestamp are set). `Samen.Auth.InvitationTransition`
          # re-asserts the SAME `status == "pending"` guard as a Postgres
          # `WHERE` clause inside its own transaction immediately before the
          # write (belt-and-suspenders on top of this flag), so the single-use
          # property does not depend on Ash's atomic-bulk-update codepath.
          update :accept do
            accept([])
            argument(:accepted_at, :utc_datetime, allow_nil?: false)
            require_atomic?(false)
            change(set_attribute(:status, "accepted"))
            change(set_attribute(:accepted_at, arg(:accepted_at)))
          end

          # The admin-gated pending -> revoked cancel (RBAC policy below).
          update :revoke do
            accept([])
            argument(:revoked_at, :utc_datetime, allow_nil?: false)
            require_atomic?(false)
            change(set_attribute(:status, "revoked"))
            change(set_attribute(:revoked_at, arg(:revoked_at)))
          end

          # The system pending -> expired transition, driven lazily by
          # `Samen.Identity.Invite` when an accept attempt discovers the row
          # is past `expires_at` (ADR-035 §4.2's "standing sweep" is the
          # eventual driver; this lazy transition makes `expired` reachable
          # today without a new Oban job).
          update :expire do
            accept([])
            require_atomic?(false)
            change(set_attribute(:status, "expired"))
          end
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # ADR-035 §5 A2 — the ADR's named exemplar of a capability an
          # UNVERIFIED credential may not reach ("may NOT send invitations").
          # Additive to (ANDed with) the OrgScope policy above: an actor must
          # be BOTH in-org AND verified to create an invitation.
          policy action(:create) do
            authorize_if(Samen.Policy.Verified)
          end

          # ADR-035 §5 A5 — role selection bounded by the inviter's-rank
          # ceiling (the Membership `ManageRole` precedent — "no invite above
          # your own rank"): the actor must be admin+ AND may not invite a
          # role it could not itself grant.
          policy action(:create) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            forbid_unless(Samen.Policy.ManageRole)
            authorize_if(always())
          end

          # The admin-gated cancel — org-scoped (broad policy above) + admin+.
          policy action(:revoke) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          # `:accept`/`:expire` are pre-actor / system transitions — no actor
          # exists yet at accept time (ADR-035 §6 "pre-actor public"). Reachable
          # ONLY via `Samen.Identity.Invite`'s internal `authorize?: false`
          # calls; any actor-based attempt is refused (defense in depth, the
          # same fail-closed posture `Credential`/`AuthToken`/`Session` use).
          policy action([:accept, :expire]) do
            forbid_if(always())
          end

          policy action(:reveal_invitation) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Credential — ADR-035 §3.1: THE authentication principal (one human, N orgs).
  # Org-LESS (sign-in resolves BEFORE an org actor exists). No PII: `email_bidx`
  # is a non-reversible keyed-HMAC lookup index (ADR-035 §4.1), never the vault.
  # Default-deny policies — reachable ONLY through the auth module's governed
  # actions (`authorize?: false` internal calls), never actor CRUD.
  # ---------------------------------------------------------------------------
  defmacro define_credential(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.Credential — THE authentication principal (doc scope table
        `credential`; ADR-035 §3.1). Org-less: one human may hold Memberships in
        many orgs, each via its own org-scoped `Identity.User`, all linked back to
        ONE Credential. No PII lives here except the ADR-035 §5 A7 TOTP/recovery
        material below — `email_bidx` is a non-reversible keyed-HMAC lookup index
        (`Samen.Auth.BlindIndex`, ADR-035 §4.1), NOT the vault, and NOT a disguised
        plaintext column (INV-1). `password_hash` / `hash_scheme` / `email_bidx`
        are credential-class columns (the ApiKey `token_digest` precedent):
        `public?: false`, never allowlisted, never actor-reachable — no
        `json_api`, no `show_fields`, no tenant read policy.

        ## ADR-035 §5 A7 — TOTP 2FA + vaulted recovery codes

        `totp_secret` and `recovery_codes` are vault-routed under `:pii_secret`
        (the Webhook `signing_secret` precedent — secret material, per-subject
        encrypted, crypto-shredded with the subject, masked everywhere by
        default; NEVER a `reveal` action here — same "no actor-reachable
        read/write, ever" posture as the rest of this resource. The single read
        path is `Samen.Vault.reveal/3` called by `Samen.Identity.Totp`, bound to
        `subject_id: credential_id` — the self-plane/tenant-as-owner rule, never
        a plane bypass). `totp_secret` stores the raw TOTP secret
        BASE64-ENCODED (`Samen.Web.Auth.Totp.encode_secret/1`) — vaulted
        plaintext must be a valid UTF-8 string, and NimbleTOTP's raw secret
        bytes are not. `recovery_codes` stores a JSON array of
        `%{"digest" => sha256_hex, "used_at" => iso8601 | nil}` — the RAW codes
        are shown to the user exactly once at enrollment/regeneration and are
        NEVER persisted; only their digests, and even those live behind the
        vault (defense in depth beyond hashing alone, since a short
        human-typed recovery code has far less entropy than the 256-bit
        `AuthToken`/`Session` tokens the plain-hash precedent covers).

        `totp_enabled_at` is `nil` until enrollment is CONFIRMED by a valid
        code (`Samen.Identity.Totp.enroll/4` writes secret + recovery codes +
        `totp_enabled_at` together, atomically — no half-enrolled state ever
        persists). `totp_last_verified_at` is the anti-replay watermark
        (`Samen.Identity.Totp.verify_totp_code/3`): the last TIMESTEP a TOTP
        code was accepted, so the SAME code cannot verify twice.
        """
        use Samen.Resource,
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
          # Org-less anchor (like Identity.Org itself): declaring org_id here
          # (nullable) stops CoreAttributes injecting a NOT-NULL org_id this
          # resource can never satisfy — a Credential predates any org actor.
          attribute(:org_id, :uuid, public?: false, allow_nil?: true)

          # Non-reversible keyed-HMAC lookup index (ADR-035 §4.1). Unique = the
          # global "one account per email" invariant. NEVER the plaintext email.
          attribute(:email_bidx, :string, public?: false, allow_nil?: false)

          # PBKDF2-SHA256-encoded hash (Samen.Auth.Hasher). `nil` is a valid,
          # deliberate state for an SSO-only (passwordless) credential (A6) —
          # password sign-in simply fails for it; never treated as "unset".
          attribute(:password_hash, :string, public?: false, allow_nil?: true)

          # e.g. "pbkdf2-sha256$600000" — travels with the hash so a future
          # iteration-count bump can still verify old rows under their own params.
          attribute(:hash_scheme, :string, public?: false, allow_nil?: true)

          attribute(:verified_at, :utc_datetime, public?: false, allow_nil?: true)

          # ADR-035 §5 A7 — nil until enrollment is CONFIRMED (a valid code was
          # entered); `Samen.Identity.Totp.enroll/4` is the ONLY writer, and it
          # sets this in the SAME atomic update as the secret/recovery codes —
          # no window where a secret exists but 2FA isn't really on yet.
          attribute(:totp_enabled_at, :utc_datetime, public?: false, allow_nil?: true)

          # ADR-035 §5 A7 anti-replay watermark — the last TOTP timestep
          # ACCEPTED (not merely attempted). `Samen.Identity.Totp.verify_totp_code/3`
          # is the only writer, inside the SAME locked transaction that checked
          # the code, so a concurrent replay of the identical code cannot both
          # succeed. Non-PII (a timestamp), never gates auth on its own.
          attribute(:totp_last_verified_at, :utc_datetime, public?: false, allow_nil?: true)
        end

        pii do
          vault(:pii_secret)

          # ADR-035 §5 A7 — 🔒 the TOTP shared secret, base64-encoded before
          # vaulting (see moduledoc). Scalar PII, the Webhook `signing_secret`
          # precedent. Deliberately NO `reveal(...)` marker: Credential grants
          # no actor-facing reveal for ANYTHING (see the `policies do` block
          # below) — the sole read path is `Samen.Vault.reveal/3` called
          # directly by `Samen.Identity.Totp`, bound to the credential as its
          # own subject.
          pii_attribute(:totp_secret, :string, vault: :pii_secret)

          # ADR-035 §5 A7 — 🔒 the recovery-code set (JSON: digest + used_at per
          # code). Same posture as `totp_secret` — vaulted, no reveal action.
          pii_attribute(:recovery_codes, :string, vault: :pii_secret)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          # Credential material is never actor-reachable — no read, no write, for
          # ANY actor. The auth module's governed actions (Samen.Identity.Register
          # and friends) call in with `authorize?: false` (the internal-write
          # posture every framework engine uses, e.g. Notifications.Engine,
          # Erasure) — never through a policy grant.
          policy always() do
            forbid_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AuthToken — ADR-035 §4.2: single-use, expiring, hashed-at-rest emailed
  # secrets (email_verify / password_reset / email_change / totp_pending).
  # Org-less (belongs_to credential, which is itself org-less). Default-deny
  # policies, same posture as Credential.
  # ---------------------------------------------------------------------------
  defmacro define_auth_token(module, otp_app, domain, repo, abbrev, credential_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.AuthToken — a single-use, expiring, hashed-at-rest emailed
        secret (doc scope table `auth_token`; ADR-035 §4.2). Extends the ApiKey
        `token_digest` precedent: the RAW token appears only inside the emailed
        link and is NEVER persisted — only its SHA-256 `token_digest`. Org-less
        (belongs_to a Credential, itself org-less); default-deny policies,
        reachable only through the auth module's governed mint/consume actions.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_auth_token")
          repo(unquote(repo))
        end

        attributes do
          # Org-less (like Credential): no org actor exists at mint/consume time
          # for most contexts (email_verify rides the pre-actor signup flow).
          attribute(:org_id, :uuid, public?: false, allow_nil?: true)

          # SHA-256 digest of the 32-random-byte raw token. One-way; the raw
          # token is never stored (ADR-035 §4.2 — the ApiKey precedent).
          attribute(:token_digest, :string, public?: false, allow_nil?: false)

          # Bounded enum (ADR-035 §4.2 table). Only :email_verify is minted by
          # A1 (T02); the others are reserved for their owning requirements
          # (A3 password_reset, settings email_change, A7 totp_pending).
          attribute(:context, :atom,
            public?: false,
            allow_nil?: false,
            constraints: [one_of: [:email_verify, :password_reset, :email_change, :totp_pending]]
          )

          # Binds the token to the address it was emailed to (ADR-035 §4.2) — an
          # email change invalidates in-flight tokens. Non-reversible bidx, never
          # the plaintext.
          attribute(:sent_to_bidx, :string, public?: false, allow_nil?: true)

          attribute(:expires_at, :utc_datetime, public?: false, allow_nil?: false)
          attribute(:consumed_at, :utc_datetime, public?: false, allow_nil?: true)
        end

        relationships do
          belongs_to :credential, unquote(credential_mod) do
            public?(false)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # ADR-035 §4.2 — the ONE atomic single-use consume action shared by
          # every emailed-token context (A2 email_verify, A3 password_reset).
          # `accept []` — no public input; the caller supplies `consumed_at`
          # as an argument, force-set via `set_attribute`, never accepted as
          # a raw changeset value. Called ONLY through
          # `Samen.Auth.TokenConsume.consume_once/3`, which scopes the QUERY
          # this action runs against to `token_digest == ^digest and context
          # == ^context and is_nil(consumed_at) and expires_at > ^now` and
          # forces `strategy: [:atomic]` — a single `UPDATE ... WHERE ...
          # RETURNING` statement, so a replayed (already-consumed) or expired
          # token matches zero rows: it can NEVER be double-consumed, even
          # racing two concurrent callers (the second's WHERE no longer
          # matches once the first's UPDATE commits).
          update :consume do
            accept([])
            argument(:consumed_at, :utc_datetime, allow_nil?: false)
            change(set_attribute(:consumed_at, arg(:consumed_at)))
          end
        end

        policies do
          # Same posture as Credential: no actor-reachable read/write. Governed
          # mint/consume actions call in with `authorize?: false`.
          policy always() do
            forbid_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Session — ADR-035 §3.1/§4.3: a revocable, DB-backed login session. Org-less
  # (belongs_to credential, itself org-less). Introduced here (T03) as the
  # minimal shape A3's "revoke all sessions on reset" needs; T04 (A4) builds the
  # full remember-me/listing/revocation surface on top of this SAME resource —
  # no second Session table, no schema churn at T04 time.
  # ---------------------------------------------------------------------------
  defmacro define_session(module, otp_app, domain, repo, abbrev, credential_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.Session — a revocable, DB-backed login session (doc scope table
        `session`; ADR-035 §3.1/§4.3). Org-less (belongs_to a Credential, itself
        org-less) — a session authenticates a CREDENTIAL, before any one org is
        selected. Revocation is row-level and immediate: `revoked_at` (or a
        delete) makes every subsequent resolve fail — no stateless-JWT
        non-revocability by design.

        No PII: `device_label` is a bounded browser/OS-family string derived from
        the user agent; the raw user-agent and the client IP are NOT stored
        (mask-unknown-by-default posture, ADR-035 §4.3). `token_digest` is the
        SHA-256 digest of the raw session token (the ApiKey `token_digest`
        precedent) — the raw token is never persisted, only carried in the
        signed+encrypted session cookie.

        Default-deny policies, same posture as Credential/AuthToken: reachable
        only through the auth module's governed actions (`authorize?: false`
        internal writes), never a tenant read policy or `json_api`/`show_fields`.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_session")
          repo(unquote(repo))
        end

        attributes do
          # Org-less anchor, same reasoning as Credential/AuthToken above.
          attribute(:org_id, :uuid, public?: false, allow_nil?: true)

          # SHA-256 digest of the 32-random-byte raw session token. One-way; the
          # raw token lives only in the signed+encrypted Phoenix session cookie
          # (ADR-035 §4.3 — the `"samen_session_token"` key), never here.
          attribute(:token_digest, :string, public?: false, allow_nil?: false)

          # Best-effort/throttled touch (the ApiKey `mark_used` precedent) —
          # never gates auth.
          attribute(:last_seen_at, :utc_datetime, public?: false, allow_nil?: true)

          # Sessions slide: expires_at = last_seen + remember-me window (A4).
          attribute(:expires_at, :utc_datetime, public?: false, allow_nil?: false)

          # nil = live session; set = revoked (immediate, row-level).
          attribute(:revoked_at, :utc_datetime, public?: false, allow_nil?: true)

          # Bounded browser-family + OS-family string (e.g. "Safari on macOS") —
          # NEVER the raw user-agent, NEVER an IP (ADR-035 §4.3 non-PII posture).
          attribute(:device_label, :string, public?: false, allow_nil?: true)

          # ADR-035 §4.3 A4 (T104) — MICROSECOND-precision creation timestamp,
          # session-local override of the universal second-precision
          # (`:utc_datetime`) `inserted_at` that `Samen.Transformers.CoreAttributes`
          # would otherwise inject. Rationale: the org concurrent-session cap
          # eviction (`Samen.Auth.SessionCreate.evict_to_cap`) must revoke the
          # GENUINELY oldest live session; at second precision, sign-ins minted in
          # the same wall-clock second carried IDENTICAL `inserted_at`, so the
          # `sort(inserted_at: :asc)` tie resolved in arbitrary Postgres order and
          # an arbitrary (not the oldest) session was evicted — a correctness gap
          # (~1-in-7 CI flake). Widening THIS column to `:utc_datetime_usec` gives
          # same-second sign-ins a sub-second creation-order key; eviction sorts
          # `{inserted_at (µs), id}` — a strict total order (the unique UUID `id`
          # is the final tiebreak for the astronomically-rare same-µs collision).
          # `CoreAttributes` is additive-only and skips `inserted_at` because this
          # resource now declares it. Semantics are unchanged from the injected
          # create-timestamp — `writable?: false`, filled by the default at create
          # (`DateTime.utc_now/0` is already µs-precision); only the precision widens.
          attribute(:inserted_at, :utc_datetime_usec,
            public?: true,
            allow_nil?: false,
            writable?: false,
            default: &DateTime.utc_now/0
          )
        end

        relationships do
          belongs_to :credential, unquote(credential_mod) do
            public?(false)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # ADR-035 §4.3 revoke — `accept []`, no public input; the caller
          # supplies `revoked_at` as an argument (`Samen.Auth.SessionRevoke`).
          # A4 (T04) extends this SAME action for individual/revoke-others.
          update :revoke do
            accept([])
            argument(:revoked_at, :utc_datetime, allow_nil?: false)
            change(set_attribute(:revoked_at, arg(:revoked_at)))
          end

          # ADR-035 §4.3 A4 (T04) — the best-effort/throttled sliding touch
          # (`Samen.Auth.SessionResolve.touch/2`): `last_seen_at`/`expires_at`
          # are BOTH `public?: false` (never actor-writable, never gate auth),
          # so — same shape as `:revoke` above — this action takes its values
          # ONLY via explicit arguments, never `accept :*`.
          update :touch do
            accept([])
            argument(:last_seen_at, :utc_datetime, allow_nil?: false)
            argument(:expires_at, :utc_datetime, allow_nil?: false)
            change(set_attribute(:last_seen_at, arg(:last_seen_at)))
            change(set_attribute(:expires_at, arg(:expires_at)))
          end
        end

        policies do
          # Same posture as Credential/AuthToken: no actor-reachable read/write
          # for ANY actor. The auth module's governed actions (session create,
          # A3 revoke-all-on-reset, A4's listing/revocation surface) call in
          # with `authorize?: false` — never through a policy grant.
          policy always() do
            forbid_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # UserIdentity — ADR-035 §3.1/§5 A6: the SSO link. Org-less (belongs_to
  # credential, itself org-less). Binds an external IdP subject (`provider` +
  # opaque `provider_uid`) to a Credential, so a returning SSO sign-in resolves
  # to the SAME principal every time. No PII: the IdP-asserted email is used
  # TRANSIENTLY at link time (a bidx lookup, ADR-035 §4.1) and — when it
  # provisions a fresh account — flows through the User's vault write path; it
  # is NEVER persisted on this row. Default-deny policies, same posture as
  # Credential/AuthToken/Session: reachable ONLY through the OIDC module's
  # governed link/unlink/provision actions (`authorize?: false` internal
  # writes), never actor CRUD, no `json_api`/`show_fields`.
  # ---------------------------------------------------------------------------
  defmacro define_user_identity(module, otp_app, domain, repo, abbrev, credential_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.UserIdentity — the SSO link (doc scope table `user_identity`;
        ADR-035 §3.1/§5 A6). Org-less (belongs_to a Credential, itself org-less):
        an external IdP identity (`provider` + opaque `provider_uid`) is bound to
        exactly one Credential, so a returning OIDC sign-in resolves to the SAME
        principal. No PII lives here — the IdP-asserted email is used transiently
        for a `Samen.Auth.BlindIndex` lookup at link time (ADR-035 §4.1) and, when
        it JIT-provisions an account, flows through the `Identity.User` vault write
        path; no plaintext IdP email is ever persisted on this row (INV-1).

        `provider`/`provider_uid` are credential-class columns (the ApiKey
        `token_digest` precedent): `public?: false`, never allowlisted, set ONLY
        via `force_change_attribute` from `Samen.Identity.OidcLink` (never a public
        create/update input). The unique index on `(provider, provider_uid)` (in
        the mount migration) makes one IdP subject map to at most one Credential.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_user_identity")
          repo(unquote(repo))
        end

        attributes do
          # Org-less anchor, same reasoning as Credential/Session/AuthToken above.
          attribute(:org_id, :uuid, public?: false, allow_nil?: true)

          # Bounded provider name (ADR-035 §5 A6 — OIDC-only build, Google the
          # built reference; SAML is a documented seam, not a value here). An
          # `:atom` with a bounded `one_of` (the Membership `role` precedent) —
          # a new OIDC provider is added by extending this list, not by opening
          # the column to arbitrary strings. Stored as text in postgres.
          attribute(:provider, :atom,
            public?: false,
            allow_nil?: false,
            constraints: [one_of: [:google]]
          )

          # The opaque IdP subject identifier (OIDC `sub`). NOT PII — an
          # IdP-scoped opaque handle, never an email/name.
          attribute(:provider_uid, :string, public?: false, allow_nil?: false)

          attribute(:linked_at, :utc_datetime, public?: false, allow_nil?: false)
        end

        relationships do
          belongs_to :credential, unquote(credential_mod) do
            public?(false)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          # Same posture as Credential/AuthToken/Session: no actor-reachable
          # read/write for ANY actor. `Samen.Identity.OidcLink`'s link/unlink/
          # provision paths call in with `authorize?: false`.
          policy always() do
            forbid_if(always())
          end
        end
      end
    end
  end
end
