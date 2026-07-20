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
  # ---------------------------------------------------------------------------
  defmacro define_invitation(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.Invitation — a pending org invitation 🔒 (doc scope table
        `invitation🔒`). The invitee `email` is vault-routed PII (masked by default;
        plaintext only via the declared reveal action under a grant). Org-scoped.
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
          # A random, non-PII acceptance token (opaque). Not the email.
          attribute(:accept_token, :string, public?: true)
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
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:reveal_invitation) do
            authorize_if(always())
          end
        end
      end
    end
  end
end
