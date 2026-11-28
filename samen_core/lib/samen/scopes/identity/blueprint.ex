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

        resource do
          description(
            "The tenant anchor: one row per organization. The generic create takes only a name and slug and is open to anyone; read is limited to the actor's own organization row, update needs the admin role and destroy needs the owner role."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_org")
          repo(unquote(repo))
        end

        unquote(json_api_block)

        attributes do
          attribute(:name, :string,
            public?: true,
            allow_nil?: false,
            description: "Display name of the organization; required, and no uniqueness rule is enforced on it."
          )
          attribute(:slug, :string,
            public?: true,
            description: "Optional short text identifier of the organization; no format rule. The create, update and account-opening actions refuse a non-empty slug that matches another organization's slug (trimmed, ignoring case) or id; an empty slug is not checked."
          )
          # Tier-0 config: plan is a bounded config value on the org row.
          attribute(:plan, :string,
            public?: true,
            default: "free",
            description: "Plan key as text, free by default. The generic create and update do not accept it; the onboarding plan step writes it (owner only, configured plan choices only, closed once onboarded), as does the operator account-opening action."
          )

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
            constraints: [min: 1],
            description: "Optional cap, at least 1, on a credential's live (unrevoked, unexpired) sessions, applied at sign-in: each sign-in revokes the credential's oldest live sessions beyond cap - 1 before creating its own; empty means unlimited. The smallest cap across the organizations it has memberships in applies."
          )

          # ADR-035 §5 A8 (T08) — the onboarding-wizard COMPLETION marker: a Tier-0
          # org setting, nil until `Samen.Web.Onboarding.complete!/3` lands it. This
          # is what makes the wizard "never re-trap" (its own moduledoc): every
          # mount checks THIS column, never client-side/session state, so the
          # checklist cannot resurrect itself on a later visit once finished.
          attribute(:onboarded_at, :utc_datetime,
            public?: true,
            allow_nil?: true,
            description: "When the onboarding wizard was completed. Samen.Web.Onboarding.complete! sets it as an admin write; the wizard is offered only while it is empty. Not an input of the generic create or update."
          )

          # The org anchor is org-LESS: it IS the tenant boundary, so its own
          # `org_id` is meaningless. Declare it nullable here so `CoreAttributes`
          # does not inject a NOT-NULL `org_id` the anchor can never satisfy. The
          # `OrgIsSelf` policy scopes by `id`, not `org_id`.
          attribute(:org_id, :uuid,
            public?: true,
            allow_nil?: true,
            description: "Optional here: the organization is the tenant boundary, so its policies decide access by the row's own id, not by this column. Only the operator account-opening action accepts it, and it must be the acting actor's own organization (the operator console's), under which the account is filed."
          )
        end

        actions do
          defaults([:read])

          # Create takes the org's `name` and `slug` ONLY. The default `create: :*` also accepted
          # `plan`, `onboarded_at` and `org_id` (an operator-host Org created with `org_id` = the
          # operator org shows up as a fake account). Seeds/helpers that need those set them with
          # `force_change_attribute` under `authorize?: false`, never as input.
          create :create do
            primary?(true)
            accept([:name, :slug])
            change(Samen.Identity.SlugFree)
          end

          # The OPERATOR's account create (`Samen.Web.Operator.AccountsLive` "New account"): an account
          # row lives in the operator org's own book, so it carries `org_id` (server-side, never client
          # input) and a `plan`. Unlike `:create` this one is policy-gated (below): the actor must be
          # scoped to that very org.
          create :open_account do
            accept([:name, :slug, :plan, :org_id])
            change(Samen.Identity.SlugFree)
          end

          # Settings update (admin+, policy below): name/slug/session cap only. `plan` and
          # `onboarded_at` are NOT inputs — a tenant actor must never write `plan` to an
          # arbitrary string. The onboarding steps (`Samen.Web.Onboarding.select_plan/4`,
          # `complete!/3`) validate the plan against the host's configured choices and
          # `force_change_attribute` it; billing/operator paths set it the same way.
          update :update do
            primary?(true)
            accept([:name, :slug, :max_concurrent_sessions])
            change(Samen.Identity.SlugFree)
            # the admin+ SimpleCheck cannot be folded into an atomic UPDATE ... WHERE
            require_atomic?(false)
          end

          # Destroy is the owner's alone (policy below).
          destroy :destroy do
            primary?(true)
          end

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

          # `:open_account` writes `org_id`/`plan`, two checks (both must hold):
          #   1. the actor must be scoped to the very org the row is filed under (the operator org);
          #   2. the changeset must carry `context: %{samen_operator_write: true}`.
          # The operator console acts through the plane's synthetic `:member` scope
          # (`Samen.Web.Plane.scope/2`), so THIS policy cannot see the authenticated operator role. The
          # console gates the event on the operator write roles itself (`Samen.Web.Operator.Authz.write_role?/1`,
          # the same gate as the webhook DLQ) and only then sets the flag; the flag keeps a tenant actor
          # (viewer/member/admin) from calling this action directly. `plan` is validated against the host's
          # offered plans, and `slug` against existing orgs, by the console / `Samen.Identity.SlugFree`.
          # The always-authorized `:create` above stays the registration/bootstrap path and accepts neither
          # column.
          policy action(:open_account) do
            forbid_unless(Samen.Policy.FilesUnderActorOrg)
            forbid_unless(Samen.Policy.OperatorConsoleWrite)
            authorize_if(always())
          end

          policy action_type([:read, :update, :destroy]) do
            # The org row's own id must equal the actor's org_id (org anchor
            # self-scope). Named FilterCheck — an inline `expr(id == …)` here would
            # be hygiene-captured inside the blueprint's quote.
            authorize_if(Samen.Policy.OrgIsSelf)
          end

          # RBAC on top of self-scope (`Samen.Scope.Role`: owner = "full control of the org,
          # including billing + destroy", admin = manage the org's settings): a viewer/member
          # could previously rewrite or DELETE its own org on `OrgIsSelf` alone.
          policy action_type(:update) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          policy action_type(:destroy) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :owner})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # User — 🔒 PII: full_name (vault :pii_name), emails (vault :pii_email).
  # Org-scoped. A user belongs to an org (the org_id core column).
  # ---------------------------------------------------------------------------
  defmacro define_user(module, otp_app, domain, repo, abbrev, membership_mod, json_api? \\ false) do
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

    # Plane wording only where the resource really resolves through Samen.Api.PiiResolution (the
    # `preparations` block above exists only when the host mounted the public API).
    {full_name_desc, emails_desc} =
      if api? do
        tail = "vault-routed. A tenant-plane actor reads it in clear, an operator only under a reveal grant (else omitted; masked while impersonating), a plane-less actor masked. AI egress masks it; only a completion call can carry it in clear, if the host opts in and a grant covers it."
        {"The user's full name; " <> tail, "The user's email addresses; " <> tail}
      else
        tail = "vault-routed, so the row holds a masked vault reference and the plain value lives only in the vault; a plain read returns the masked reference, and code that resolves it through Samen.Api.PiiResolution gets it in clear on the planes that rule allows."
        {"The user's full name; " <> tail, "The user's email addresses; " <> tail}
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

        resource do
          description(
            "A person's account inside one organization, optionally linked to the sign-in credential. Full name and emails are vault-routed. Creating needs the admin role; users edit their own profile but not their status; changing or deleting another user needs the admin role and a role strictly above theirs."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_user")
          repo(unquote(repo))
        end

        unquote(json_api_block)

        attributes do
          # A non-PII display handle (safe to log/label — like the CRM display_name).
          attribute(:handle, :string,
            public?: true,
            description: "Display handle of the user as plain free text, not vault-routed; no format or uniqueness rule is enforced."
          )
          attribute(:status, :string,
            public?: true,
            default: "active",
            description: "Account status as text, active by default; no fixed list of values is enforced. An actor's write cannot change their own status; changing another user's needs an admin role that strictly out-ranks that user's role in the organization."
          )

          # ADR-035 §3.1 — additive, nullable FK to the org-less Credential (THE
          # authentication principal; one human, N orgs, N per-org Users). Nullable
          # so existing User rows created before the identity spine mounted (or by
          # a host still on BYO-auth/ADR-031) are unaffected — no migration break.
          attribute(:credential_id, :uuid,
            public?: false,
            allow_nil?: true,
            description: "Id of the sign-in credential this user is linked to; empty for a user created without one. Not publicly writable: set when registration, invitation acceptance or SSO provisioning creates the user."
          )
        end

        pii do
          vault(:pii_name)
          vault(:pii_email)

          pii_attribute(:full_name, Samen.Type.FullName,
            vault: :pii_name,
            description: unquote(full_name_desc)
          )
          pii_attribute(:emails, Samen.Type.Emails,
            vault: :pii_email,
            description: unquote(emails_desc)
          )

          reveal(:reveal_user)
        end

        unquote(api_preparations)

        actions do
          defaults([:read, :destroy, create: :*])

          # `org_id` is NOT an update input (the default `update: :*` accepted it: a user could be moved into another
          # org, identity-authz review 2, #3); a user's org is fixed at create.
          update :update do
            primary?(true)
            require_atomic?(false)
            accept([:handle, :status, :full_name, :emails])
          end

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
            argument(:subject_id, :string, allow_nil?: false)

            run({Samen.Reveal.GrantProbe, label: :emails})
          end
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # Creating a user row (which may carry a credential_id) is an admin act.
          policy action_type(:create) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
            authorize_if(always())
          end

          # A user edits their own profile; changing another user, or anyone's status, or
          # destroying a user, needs the rank rule membership updates use (identity-authz
          # review 3, B). OrgScope above is the tenant boundary, this is the intra-org rule.
          policy action_type([:update, :destroy]) do
            forbid_unless({Samen.Policy.ManageUser, membership: unquote(membership_mod)})
            authorize_if(always())
          end

          # The reveal action is generic (not a data read/write); its own grant gate
          # inside the run/2 is the real control. Allow it to run for any actor —
          # the grant check denies by default.
          policy action(:reveal_user) do
            authorize_if(actor_present())
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

        resource do
          description(
            "Gives a user an RBAC role in the organization; a create is refused when the user already has a membership there. Reads are organization-scoped; writes need the admin role, and any role being set and any role the row holds must each be strictly below the writer's own."
          )
        end

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
            constraints: [one_of: Samen.Scope.Role.all()],
            description: "RBAC role of the member: owner, admin, member or viewer, member by default. Roles are ranked. An actor's write must set a role strictly below its own, and changing or deleting a row also needs its stored role strictly below, so an admin can neither assign admin nor change an admin or owner."
          )

          attribute(:status, :string,
            public?: true,
            default: "active",
            description: "Membership status as text, active by default; no fixed list of values is enforced. Only an active membership resolves a role in the organization for a signed-in session or an API key; any other status resolves none."
          )
        end

        relationships do
          belongs_to :user, unquote(user_mod) do
            description("The user this membership grants a role to; required, in the same organization, and no action changes it after creation.")
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        # F3.5 same-org FK: a membership may only reference a same-org user.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:user]})
          change(Samen.Identity.OneMembership, on: [:create])
        end

        actions do
          defaults([:read, :destroy, create: :*])

          # A membership UPDATE changes its `role` and `status` only (still under `ManageRole`, below). The default
          # `update: :*` also accepted `org_id` and `user_id`, so an admin could move a lower-ranked membership into
          # another org or re-point it at another user (identity-authz review 2, #3). A membership's org and user are
          # fixed at create.
          update :update do
            primary?(true)
            require_atomic?(false)
            accept([:role, :status])
          end

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

        resource do
          description(
            "Per-organization configuration rows for the RBAC roles, holding a label, a rank and an enabled flag; reads are organization-scoped and writes need the admin role. Authorization checks use the fixed ranks of Samen.Scope.Role, not these rows."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_role")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :atom,
            public?: true,
            allow_nil?: false,
            constraints: [one_of: Samen.Scope.Role.all()],
            description: "Which RBAC role this row configures: owner, admin, member or viewer; required."
          )

          attribute(:label, :string,
            public?: true,
            description: "Optional display label for the role as free text; no format is enforced."
          )
          attribute(:rank, :integer,
            public?: true,
            allow_nil?: false,
            description: "Required whole number ranking the role on this row; authorization uses the fixed ranks of Samen.Scope.Role, and no range or uniqueness rule is enforced here."
          )
          attribute(:enabled, :boolean,
            public?: true,
            default: true,
            description: "Whether the role is marked enabled in this organization's configuration, true by default; no authorization check reads it."
          )
        end

        actions do
          defaults([:read, :destroy, create: :*])

          # The generic update takes the role definition's own fields. `org_id` is NOT an input: the default
          # `update: :*` accepted it, so an admin could move a role row into another org (identity-authz review 2, #3).
          update :update do
            primary?(true)
            require_atomic?(false)
            accept([:name, :label, :rank, :enabled])
          end
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

        resource do
          description(
            "An API credential bound to one plane and to the membership that minted it. Only a SHA-256 digest of the key is stored. Creating, re-timing, revoking or deleting one needs the admin role, and a key created through an actor cannot carry a role above the creator's."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_api_key")
          repo(unquote(repo))
        end

        attributes do
          # SHA-256 digest of the key material. One-way; the raw key is never stored.
          attribute(:token_digest, :string,
            public?: false,
            allow_nil?: false,
            description: "SHA-256 hex digest of the key material; required and unique across keys (a database index), and the raw key is never stored. Not public and never an action input: the minting code sets it, e.g. Samen.Web.Settings.ApiKeys.mint where a host mounts the settings surface."
          )

          attribute(:plane, :atom,
            public?: true,
            allow_nil?: false,
            default: :tenant,
            constraints: [one_of: [:tenant, :operator]],
            description: "Kind of key, tenant by default: tenant or operator; no action changes it after creation. A host that authenticates keys from this table gives the request actor this plane; where PII is resolved through Samen.Api.PiiResolution an operator key gets a vault-routed field only under a reveal grant."
          )

          # Declared scopes as a bounded map: %{scope => [:read,:write]} (`all`, a family, or
          # `family.type`). Over the JSON:API its authority is the lower of these scopes and the minter's role.
          attribute(:scopes, :map,
            public?: true,
            default: %{},
            description: "Scopes: all, a family (crm) or family.type (crm.contact), each read, write or both. A request over the JSON:API needs a scope that covers the action and a role that allows it; no scopes authorizes nothing. MCP does not read them. No action changes it; create refuses an empty or malformed set."
          )

          # The role of the minting membership — the actor ceiling this key inherits.
          attribute(:minter_role, :atom,
            public?: true,
            constraints: [one_of: Samen.Scope.Role.all()],
            description: "Role recorded at mint (owner, admin, member or viewer); required on create; no action changes it afterwards. Made through an actor it cannot exceed the actor's role or the bound membership's. effective_role takes the lower of this and that membership's current role, refusing a non-active one."
          )

          attribute(:revoked_at, :utc_datetime,
            public?: true,
            description: "When the key was revoked, empty while it is live. No action accepts it as input; the revoke action sets it once and keeps the original instant on a repeat, and Samen.Scope.ApiKey.active_query skips rows where it is set."
          )

          # F3.4 — bounded expiry (deny-on-read). Every minted key carries a hard
          # time ceiling (`Samen.Scope.ApiKey.bounded_expiry/2`); the auth lookup
          # filters `expires_at > now` so an expired row is never resolved to an
          # actor. `nil` is a legacy pre-gate row (non-expiring predicate); the
          # minter never produces one.
          attribute(:expires_at, :utc_datetime,
            public?: true,
            description: "Hard expiry instant. Create clamps it to at most 365 days ahead (90 days when empty); an update that sets it can only shorten it and refuses a revoked or expired key. Samen.Scope.ApiKey.active_query refuses a key at or past it; a key with none (from before the expiry gate) does not expire."
          )

          # F3.4 — last-use observability. Best-effort stamped by the auth path on a
          # successful resolve; supports stale-key hygiene reporting. Never gates auth.
          attribute(:last_used_at, :utc_datetime,
            public?: true,
            description: "When a host's key check last stamped the key as used, through the system-only mark_used action; best-effort, empty where the host does not stamp it, and never used to decide whether a key authenticates."
          )
        end

        relationships do
          belongs_to :membership, unquote(membership_mod) do
            description("The membership that minted the key; required, in the same organization, and no action changes it after creation. Creating a key through an actor needs it to be that actor's own active membership.")
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        # F3.5 same-org FK: an api_key may only reference a same-org membership.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:membership]})
        end

        # A key is created only with scopes inside the grammar and at least one of them (`Samen.Scope.ApiKey.Grammar`).
        validations do
          validate(Samen.Scope.ApiKey.ValidScopes, on: :create)
        end

        actions do
          defaults([:read, :destroy])

          # Default create: `minter_role` is bounded by `Samen.Policy.MinterRoleCeiling`
          # (policy below) and `expires_at` is ALWAYS clamped into `(now, now + max_ttl]`
          # by `Samen.Scope.ApiKey.ClampExpiry`. `revoked_at` is NOT an input (a key is
          # born live; revocation is `:revoke`); `token_digest` is `public?: false`, so
          # it can only be force-set by the minter, never supplied as input.
          create :create do
            primary?(true)
            accept([:org_id, :plane, :scopes, :minter_role, :expires_at, :membership_id])
            change(Samen.Scope.ApiKey.ClampExpiry)
            validate(present(:minter_role))
          end

          # The ONLY actor-facing update: re-time a key. Role, plane, scopes, digest and
          # revocation are immutable after mint (a wider key is a NEW key, minted under
          # the ceiling check); expiry is re-clamped on every change.
          update :update do
            primary?(true)
            accept([:expires_at])
            require_atomic?(false)
            change(Samen.Scope.ApiKey.ClampExpiry)
          end

          # Revocation is one-way: sets `revoked_at` once (a second revoke keeps the
          # original instant) and takes no input, so nothing can clear or back-date it.
          update :revoke do
            accept([])
            require_atomic?(false)

            # `revoked_at` becomes `coalesce(revoked_at, now)` IN THE UPDATE: it never depends on what the
            # record in hand happens to carry (a row read with `select` omitting `revoked_at` is
            # `%Ash.NotLoaded{}`; an `is_nil` test on it failed OPEN, answering `{:ok, _}` with the key
            # still live), and a second revoke keeps the original instant even under concurrency.
            change(Samen.Scope.ApiKey.RevokeOnce)
          end

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

          # `:mark_used` is the authentication path's own stamp ("last used" is evidence a key was presented). It
          # runs only as the key check's internal `authorize?: false` call; no actor, an admin included, may write it.
          policy action(:mark_used) do
            forbid_if(always())
          end

          # No escalation: a minted key may not act above the actor that mints it.
          policy action(:create) do
            forbid_unless(Samen.Policy.MinterRoleCeiling)
            forbid_unless(Samen.Policy.KeyBoundToMinter)
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

        resource do
          description(
            "An invitation for an email address to join the organization with a role. Every create is pending with a 14-day expiry; it becomes accepted, revoked or expired, each only from pending; the generic update is refused. Only a digest of the invite token is stored; the invited email is vault-routed."
          )
        end

        meaning do
          synonyms(["invite"])
        end

        postgres do
          table("#{unquote(abbrev)}_invitation")
          repo(unquote(repo))
        end

        attributes do
          attribute(:role, :atom,
            public?: true,
            default: :member,
            constraints: [one_of: Samen.Scope.Role.all()],
            description: "Role a new member gets on accepting (owner, admin, member or viewer), member by default; an invitee who already has a membership there keeps it. Creating needs a verified admin or owner and a role strictly below their own; no actor can edit it afterwards."
          )

          attribute(:status, :string,
            public?: true,
            default: "pending",
            description: "Lifecycle state as text, pending by default and on every create. After that only the accept, revoke and expire actions change it, and no actor can run accept or expire or edit it directly; the column itself does not constrain the values."
          )

          # Credential-class columns (ApiKey `token_digest` precedent) —
          # `public?: false`, never allowlisted, set ONLY via
          # `force_change_attribute` from `Samen.Identity.Invite` (never a
          # public create/update input).
          attribute(:token_digest, :string,
            public?: false,
            description: "SHA-256 hex digest of the emailed invite token, unique across invitations (a database index); the raw token is never stored. Not public: set only by Samen.Identity.Invite.create when the invitation is issued."
          )

          # ADR-035 §4.1 — the non-reversible keyed-HMAC lookup index binding
          # the invite to the address it was sent to. Accept-time credential
          # matching reads THIS, never the vault (no reveal at accept).
          attribute(:email_bidx, :string,
            public?: false,
            description: "Keyed-HMAC blind index of the invited email address, used to match the invitation to an existing credential without a vault reveal. One-way, never the address itself; set by Samen.Identity.Invite.create and not public."
          )

          attribute(:expires_at, :utc_datetime,
            public?: false,
            description: "When the invitation stops being acceptable: 14 days after creation, set by every create. Accepting only matches a pending invitation still before this instant."
          )
          attribute(:accepted_at, :utc_datetime,
            public?: false,
            allow_nil?: true,
            description: "When the invitation was accepted, set by the accept action together with status accepted; empty before."
          )
          attribute(:revoked_at, :utc_datetime,
            public?: false,
            allow_nil?: true,
            description: "When the invitation was revoked, set by the revoke action (admin only, pending invitations only) together with status revoked; empty before."
          )
        end

        pii do
          vault(:pii_email)
          pii_attribute(:email, Samen.Type.Emails,
            vault: :pii_email,
            description: "The invited email addresses; vault-routed, so the row holds a masked vault reference and the plain value lives only in the vault. reveal_invitation only reports whether a grant covers the subject; the settings invitations list resolves it by plane through Samen.Api.PiiResolution."
          )
          reveal(:reveal_invitation)
        end

        actions do
          defaults([:read, :destroy])

          # EVERY create is a pending invitation with its expiry: `status` and `expires_at` are not inputs. The
          # default `create: :*` accepted `status` (an authorized admin could create an "accepted" or "revoked"
          # row) and left `expires_at` empty (an invitation that can never be accepted). `Samen.Identity.Invite`
          # sets only the credential-class columns (`token_digest`, `email_bidx`) on top of this.
          create :create do
            primary?(true)
            accept([:org_id, :role, :email])
            change(set_attribute(:status, "pending"))

            change(fn changeset, _ctx ->
              expires_at =
                DateTime.utc_now()
                |> DateTime.add(Samen.Identity.Invite.ttl_seconds(), :second)
                |> DateTime.truncate(:second)

              Ash.Changeset.force_change_attribute(changeset, :expires_at, expires_at)
            end)
          end

          # No actor-writable generic update. The default `update: :*` accepted
          # `role`/`status`/`email` under the org-scope policy alone, so ANY in-org
          # actor could raise a pending invite to `:owner` (accept then lands
          # `invitation.role`) or flip a revoked one back to `"pending"`. The
          # lifecycle moves only through `:accept`/`:revoke`/`:expire`; this
          # `:update` takes NO input and is refused to every actor (the policy
          # below) — system paths that must touch an internal column go through
          # `force_change_attribute` + `authorize?: false`.
          update :update do
            accept([])
            require_atomic?(false)
          end

          action :reveal_invitation, :map do
            argument(:subject_id, :string, allow_nil?: false)

            run({Samen.Reveal.GrantProbe, label: :email})
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

            # Only a PENDING invite can be revoked: an accepted/expired/revoked row is history and
            # must not be relabelled (fail closed on a row read without `status`).
            validate(fn changeset, _ctx ->
              case changeset.data do
                %{status: "pending"} -> :ok
                _ -> {:error, field: :status, message: "only a pending invitation can be revoked"}
              end
            end)

            # ...and the DATABASE decides again in the UPDATE (`status = 'pending'`): an accept that commits between
            # the caller's read and this write matches zero rows instead of being relabelled "revoked".
            change(Samen.Identity.OnlyPending)
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

          # Deleting an invitation erases the record (pending ones are a DoS, accepted/revoked ones are
          # history): admin+, exactly like `:revoke`. Covers bulk destroy too (the check reads only the actor).
          policy action_type(:destroy) do
            forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
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

          # The generic `:update` is closed to actors (it would otherwise pass on
          # org scope alone); role/status changes are a create-time or lifecycle
          # transition, never an in-place edit.
          policy action(:update) do
            forbid_if(always())
          end

          policy action(:reveal_invitation) do
            authorize_if(actor_present())
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

        resource do
          description(
            "The authentication principal: one row per sign-in identity, not tied to any organization. Holds the email blind index, password hash and scheme, verification time and two-factor state. Its policies refuse every actor; framework code reaches it with authorization off."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_credential")
          repo(unquote(repo))
        end

        attributes do
          # Org-less anchor (like Identity.Org itself): declaring org_id here
          # (nullable) stops CoreAttributes injecting a NOT-NULL org_id this
          # resource can never satisfy — a Credential predates any org actor.
          attribute(:org_id, :uuid,
            public?: false,
            allow_nil?: true,
            description: "Always optional here: a credential exists before any organization is chosen, so it is not scoped by this column."
          )

          # Non-reversible keyed-HMAC lookup index (ADR-035 §4.1). Unique = the
          # global "one account per email" invariant. NEVER the plaintext email.
          attribute(:email_bidx, :string,
            public?: false,
            allow_nil?: false,
            description: "Keyed-HMAC blind index of the normalized email address, unique across credentials (database index); sign-in and password reset match on it. One-way, never the address. Erasing the credential as a subject replaces it (Samen.Auth.BlindIndexErasure) with a random value of the same shape."
          )

          # PBKDF2-SHA256-encoded hash (Samen.Auth.Hasher). `nil` is a valid,
          # deliberate state for an SSO-only (passwordless) credential (A6) —
          # password sign-in simply fails for it; never treated as "unset".
          attribute(:password_hash, :string,
            public?: false,
            allow_nil?: true,
            description: "Encoded password hash from the configured hasher (PBKDF2-SHA256 by default), never the password. Empty for a passwordless SSO-only credential, for which password sign-in always fails."
          )

          # e.g. "pbkdf2-sha256$600000" — travels with the hash so a future
          # iteration-count bump can still verify old rows under their own params.
          attribute(:hash_scheme, :string,
            public?: false,
            allow_nil?: true,
            description: "Name of the hashing scheme (with its parameters) that produced password_hash; verification receives it, so a hash made with older parameters of the configured hasher still verifies. Empty for SSO-only credentials."
          )

          attribute(:verified_at, :utc_datetime,
            public?: false,
            allow_nil?: true,
            description: "When the credential's email address was confirmed: set by email verification, by invitation acceptance that creates the credential, or by SSO sign-up with a provider-verified address; empty until then."
          )

          # ADR-035 §5 A7 — nil until enrollment is CONFIRMED (a valid code was
          # entered); `Samen.Identity.Totp.enroll/4` is the ONLY writer, and it
          # sets this in the SAME atomic update as the secret/recovery codes —
          # no window where a secret exists but 2FA isn't really on yet.
          attribute(:totp_enabled_at, :utc_datetime,
            public?: false,
            allow_nil?: true,
            description: "When two-factor enrollment was confirmed; empty until then and cleared when two-factor is disabled. Samen.Identity.Totp.enroll writes it in the same update as the secret and recovery codes."
          )

          # ADR-035 §5 A7 anti-replay watermark — the last TOTP timestep
          # ACCEPTED (not merely attempted). `Samen.Identity.Totp.verify_totp_code/3`
          # is the only writer, inside the SAME locked transaction that checked
          # the code, so a concurrent replay of the identical code cannot both
          # succeed. Non-PII (a timestamp), never gates auth on its own.
          attribute(:totp_last_verified_at, :utc_datetime,
            public?: false,
            allow_nil?: true,
            description: "When a TOTP code was last accepted, written under a row lock and passed to the code validator as a replay watermark; the framework validator then refuses a code from a time step already accepted. Empty before any acceptance, and reset when two-factor is enrolled or disabled."
          )
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
          pii_attribute(:totp_secret, :string,
            vault: :pii_secret,
            description: "The TOTP shared secret, base64-encoded and stored in the pii_secret vault, never in this row. The resource has no reveal action and its policies refuse every actor; Samen.Identity.Totp decrypts it bound to this credential. Empty before enrollment and after two-factor is disabled."
          )

          # ADR-035 §5 A7 — 🔒 the recovery-code set (JSON: digest + used_at per
          # code). Same posture as `totp_secret` — vaulted, no reveal action.
          pii_attribute(:recovery_codes, :string,
            vault: :pii_secret,
            description: "The two-factor recovery codes as JSON entries of a SHA-256 digest and a used-at time, never the codes themselves; stored in the pii_secret vault. The resource has no reveal action and its policies refuse every actor; Samen.Identity.Totp decrypts it bound to this credential."
          )
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

        resource do
          description(
            "A single-use, expiring token issued to a credential: emailed for email verification or password reset, or held in the browser session for a pending two-factor step (email_change is a permitted context value). Only the SHA-256 digest is stored; its policies refuse every actor."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_auth_token")
          repo(unquote(repo))
        end

        attributes do
          # Org-less (like Credential): no org actor exists at mint/consume time
          # for most contexts (email_verify rides the pre-actor signup flow).
          attribute(:org_id, :uuid,
            public?: false,
            allow_nil?: true,
            description: "Always optional here: the token belongs to an organization-less credential, so it is not scoped by this column."
          )

          # SHA-256 digest of the 32-random-byte raw token. One-way; the raw
          # token is never stored (ADR-035 §4.2 — the ApiKey precedent).
          attribute(:token_digest, :string,
            public?: false,
            allow_nil?: false,
            description: "SHA-256 hex digest of the token, required and unique across tokens (a database index); the raw token is never stored. Not public: set only when the token is minted."
          )

          # Bounded enum (ADR-035 §4.2 table). Only :email_verify is minted by
          # A1 (T02); the others are reserved for their owning requirements
          # (A3 password_reset, settings email_change, A7 totp_pending).
          attribute(:context, :atom,
            public?: false,
            allow_nil?: false,
            constraints: [one_of: [:email_verify, :password_reset, :email_change, :totp_pending]],
            description: "What the token is for: email_verify, password_reset, email_change or totp_pending; required. Consuming a token matches its context as well as its digest."
          )

          # Binds the token to the address it was emailed to (ADR-035 §4.2) — an
          # email change invalidates in-flight tokens. Non-reversible bidx, never
          # the plaintext.
          attribute(:sent_to_bidx, :string,
            public?: false,
            allow_nil?: true,
            description: "Keyed-HMAC blind index of the email address the token was sent to, recorded at mint; never the address itself. Empty when none was given."
          )

          attribute(:expires_at, :utc_datetime,
            public?: false,
            allow_nil?: false,
            description: "When the token stops being usable; required. Consuming only matches a token still before this instant."
          )
          attribute(:consumed_at, :utc_datetime,
            public?: false,
            allow_nil?: true,
            description: "When the token was consumed, set by the atomic consume action; a token with this set no longer matches. Empty while unused."
          )
        end

        relationships do
          belongs_to :credential, unquote(credential_mod) do
            description("The credential the token was issued to; required.")
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

        resource do
          description(
            "A revocable, database-backed login session for a credential, found by the SHA-256 digest of its session token. It resolves only while neither revoked nor expired. Its policies refuse every actor; framework code reaches it with authorization off."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_session")
          repo(unquote(repo))
        end

        attributes do
          # Org-less anchor, same reasoning as Credential/AuthToken above.
          attribute(:org_id, :uuid,
            public?: false,
            allow_nil?: true,
            description: "Always optional here: a session authenticates a credential before any organization is chosen, so it is not scoped by this column."
          )

          # SHA-256 digest of the 32-random-byte raw session token. One-way; the
          # raw token lives only in the signed+encrypted Phoenix session cookie
          # (ADR-035 §4.3 — the `"samen_session_token"` key), never here.
          attribute(:token_digest, :string,
            public?: false,
            allow_nil?: false,
            description: "SHA-256 hex digest of the session token, required and unique across sessions; the raw token is never stored. Not public: set only when the session is created."
          )

          # Best-effort/throttled touch (the ApiKey `mark_used` precedent) —
          # never gates auth.
          attribute(:last_seen_at, :utc_datetime,
            public?: false,
            allow_nil?: true,
            description: "When the session was last seen, advanced by a best-effort touch throttled to once per five minutes; it never decides whether a session authenticates."
          )

          # Sessions slide: expires_at = last_seen + remember-me window (A4).
          attribute(:expires_at, :utc_datetime,
            public?: false,
            allow_nil?: false,
            description: "When the session stops resolving: 60 days after creation, moved to 60 days after each throttled touch; required. A session at or past this instant does not resolve."
          )

          # nil = live session; set = revoked (immediate, row-level).
          attribute(:revoked_at, :utc_datetime,
            public?: false,
            allow_nil?: true,
            description: "When the session was revoked, empty while live. A revoked session does not resolve; revoke actions and the sign-in cap eviction set it."
          )

          # Bounded browser-family + OS-family string (e.g. "Safari on macOS") —
          # NEVER the raw user-agent, NEVER an IP (ADR-035 §4.3 non-PII posture).
          attribute(:device_label, :string,
            public?: false,
            allow_nil?: true,
            description: "Coarse label such as a browser family on an OS family, or Unknown device, derived from the User-Agent at sign-in. The raw user-agent and the client IP are not stored."
          )

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
            default: &DateTime.utc_now/0,
            description: "When the session was created, with microsecond precision; set by default and not writable. Cap eviction sorts on it, then on id, to find the oldest live session."
          )
        end

        relationships do
          belongs_to :credential, unquote(credential_mod) do
            description("The credential this session authenticates; required.")
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

        resource do
          description(
            "The link between a credential and an external SSO identity, given by provider and the provider's subject id; the pair is unique (a database index). Its policies refuse every actor; framework code reaches it with authorization off."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_user_identity")
          repo(unquote(repo))
        end

        attributes do
          # Org-less anchor, same reasoning as Credential/Session/AuthToken above.
          attribute(:org_id, :uuid,
            public?: false,
            allow_nil?: true,
            description: "Always optional here: the link belongs to an organization-less credential, so it is not scoped by this column."
          )

          # Bounded provider name (ADR-035 §5 A6 — OIDC-only build, Google the
          # built reference; SAML is a documented seam, not a value here). An
          # `:atom` with a bounded `one_of` (the Membership `role` precedent) —
          # a new OIDC provider is added by extending this list, not by opening
          # the column to arbitrary strings. Stored as text in postgres.
          attribute(:provider, :atom,
            public?: false,
            allow_nil?: false,
            constraints: [one_of: [:google]],
            description: "The SSO identity provider; currently only google is allowed, and the value is required."
          )

          # The opaque IdP subject identifier (OIDC `sub`). NOT PII — an
          # IdP-scoped opaque handle, never an email/name.
          attribute(:provider_uid, :string,
            public?: false,
            allow_nil?: false,
            description: "Opaque subject identifier the provider issued for the account, stored as received; required, and unique together with provider."
          )

          attribute(:linked_at, :utc_datetime,
            public?: false,
            allow_nil?: false,
            description: "When the SSO identity was linked to the credential, set at link time; required."
          )
        end

        relationships do
          belongs_to :credential, unquote(credential_mod) do
            description("The credential this SSO identity signs in as; required.")
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

  # ---------------------------------------------------------------------------
  # LoginFailure — ADR-038 §6.4 (T109): the DURABLE brute-force failure counter.
  # Org-less (keyed on a non-PII bidx/credential-id, never an org actor). Default-deny
  # policies, same posture as Credential/AuthToken/Session/UserIdentity: reachable ONLY
  # through `Samen.Identity.LoginFailure`'s governed bump!/reset!/count functions and
  # the retention sweep's `:destroy`, never actor CRUD.
  # ---------------------------------------------------------------------------
  defmacro define_login_failure(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Identity.LoginFailure — the DURABLE brute-force failure counter (doc scope
        table `login_failure`; ADR-038 §6.4). ONE row per `(key_kind, key_value)` —
        `key_value` is either an `email_bidx` (non-reversible keyed-HMAC, ADR-035
        §4.1) or a credential id (UUID) — mirroring the two independent axes
        `Samen.Web.RateLimit`'s bounded `login_failed_audit` counter already bumps
        (T103): the sign-in password path keys on `email_bidx`; the post-2FA-pending
        wrong-code path keys on the already-resolved `credential` id. No IP, no PII,
        no per-attempt rows — a single upserted row per key tracks
        `failure_count`/`window_started_at`/`last_failed_at`.

        This row is what makes T103's brute-force SIGNAL survive a node restart: the
        real-time throttle (`Samen.Web.RateLimit`'s Hammer/ETS counter — §6.1's
        swappable thin backend) still gates the hot path, but every failed attempt
        ALSO writes through to this durable table
        (`Samen.Identity.LoginFailure.bump!/4`) and a successful login resets it
        (`reset!/3`) — so a restart that wipes the ETS table does not erase the
        accumulated brute-force count, and `Samen.Web.RateLimit`'s sign-in check
        additionally consults this durable row so a still-locked-out attacker stays
        locked out across a restart (see `Samen.Identity.LoginFailure.over_limit?/5`
        and `Samen.Web.Auth.SessionController`'s wiring).

        Default-deny policies (the Credential/AuthToken/Session/UserIdentity
        precedent): no actor-reachable read/write for ANY actor. Reachable only
        through `Samen.Identity.LoginFailure`'s governed functions (`authorize?:
        false` internal calls, like every other engine in this spine) and the
        `Samen.Retention` sweep's `:destroy` (30-day idle prune, keyed on
        `last_failed_at`).

        See `Samen.Identity.LoginFailure`'s moduledoc for why the WRITE path (bump!/
        reset!) is raw parametrized SQL rather than Ash changesets — a deliberate,
        documented mechanism choice (the `Samen.Webhook.Event` precedent, ADR-038
        §5.3), not a chokepoint bypass: this resource carries no PII, so none of the
        vault/PII write guards apply regardless.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        resource do
          description(
            "Brute-force counter: one row per failure key, an email blind index or a credential id, holding the failure count and window. Samen.Identity.LoginFailure upserts it atomically; a successful password or two-factor sign-in deletes that credential's rows. Its policies refuse every actor."
          )
        end

        postgres do
          table("#{unquote(abbrev)}_login_failure")
          repo(unquote(repo))
        end

        attributes do
          # Org-less anchor, same reasoning as Credential/AuthToken/Session above.
          attribute(:org_id, :uuid,
            public?: false,
            allow_nil?: true,
            description: "Always optional here: failures are keyed by email blind index or credential id, not by organization, so it is not scoped by this column."
          )

          # Bounded key-kind enum — the two independent axes T103 already bumps
          # (ADR-038 §6.2/§6.4). Never a plaintext identifier either way.
          attribute(:key_kind, :atom,
            public?: false,
            allow_nil?: false,
            constraints: [one_of: [:email_bidx, :credential]],
            description: "Kind of key the row counts failures for: email_bidx or credential; required."
          )

          # The non-reversible bidx OR a credential id (as a string) — never PII.
          attribute(:key_value, :string,
            public?: false,
            allow_nil?: false,
            description: "The counted key, an email blind index or a credential id as text matching key_kind; unique together with key_kind, and never a plaintext email."
          )

          attribute(:failure_count, :integer,
            public?: false,
            allow_nil?: false,
            default: 1,
            description: "Failed attempts counted in the current window, 1 by default; each failure adds one, and a failure after the window has expired resets it to 1."
          )

          attribute(:window_started_at, :utc_datetime_usec,
            public?: false,
            allow_nil?: false,
            description: "When the current failure window began, with microsecond precision; required. A failure after the window length restarts it."
          )

          attribute(:last_failed_at, :utc_datetime_usec,
            public?: false,
            allow_nil?: false,
            description: "When the most recent failure was recorded, with microsecond precision; required."
          )
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        policies do
          # No actor-reachable read/write for ANY actor — same posture as
          # Credential/AuthToken/Session/UserIdentity. `Samen.Identity.LoginFailure`'s
          # bump!/reset!/count functions and the retention sweep operate with
          # `authorize?: false` (or bypass Ash's authorizer entirely via raw SQL,
          # which never runs through this policy at all).
          policy always() do
            forbid_if(always())
          end
        end
      end
    end
  end
end
