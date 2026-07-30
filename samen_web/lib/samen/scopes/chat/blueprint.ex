defmodule Samen.Scopes.Chat.Blueprint do
  @moduledoc """
  Resource-definition macros for the **Chat** scope (ADR-012 §2.2) — the flagship
  cross-plane realtime chat model. A library-authored blueprint (ADR-004 shape), but hosted
  in `samen_web` (the framework library) rather than `samen_core`: chat is a
  framework-web capability (it consumes `Samen.Web.ObjectRef` + `Samen.Web.Plane`), and the
  hard rule keeps `samen_core` code untouched (only the abbrev-registry append is sanctioned).
  Every resource is still a normal `use Samen.Resource` (from the untouched kernel), so it
  inherits the SAME vault routing, `pii_reads`/`no_plaintext_pii` verifiers, `OrgScope`,
  `SameOrgFk`, and catalog wiring as every other scope — the chat scope is a THIN new
  blueprint, not a fork.

  ## The four resources

  | Resource                | Abbrev | PII | Role |
  |-------------------------|--------|-----|------|
  | `ChatThread`            | `*t`   | no  | a conversation that may span two planes |
  | `ChatParticipant`       | `*p`   | 🔒  | membership + the cross-plane grant carrier; `full_name` vaulted |
  | `ChatMessage`           | `*m`   | 🔒  | one message; `body` vaulted (Support.Message shape) |
  | `ChatDisclosureSetting` | `*d`   | no  | Tier-0 per-org identity-disclosure config |

  ## PII — participant identity + message body (🔒)

  Two resources carry 🔒 PII, and each is vaulted BY CONSTRUCTION so masking falls out of
  the kernel resolver per the viewer's plane:

  - `ChatMessage.body` → `pii_attribute :body, :string, vault: :pii_body` +
    `reveal :reveal_message` — copied VERBATIM from `Support.Message` (ADR-012 §2.1: "reuse
    where it's free"). Free-text conversation content; clear to the tenant, `••••` to the
    operator, same as everything else.
  - `ChatParticipant.full_name` → `pii_attribute :full_name, Samen.Type.FullName, vault:
    :pii_name` + `reveal :reveal_participant`. This is the participant's REAL identity. The
    3-state identity model (§5) resolves this ONE field on the tenant-plane actor (clear) when
    consent is stored, or the operator-plane actor (`••••`) otherwise — a PLANE CHOICE for one
    subject, never a bespoke masking branch. The non-PII `handle` is always safe to render on
    either plane (the label the unmasked card never leaks a real name through).

  The message body's vault and the participant identity's vault are ORTHOGONAL: the disclosure
  setting governs the participant card; the body's vault governs the message text (ADR-012 §5
  state 3 — identity disclosure ≠ content disclosure).

  ## Cross-plane grant is DATA, not a live-actor trust (§2.3)

  `ChatParticipant.party` (`:tenant | :operator`) records which plane each participant acts
  from. A cross-plane thread is OWNED BY THE TENANT ORG; the operator reaches it through the
  existing impersonation bridge carrying the tenant `org_id`, so `OrgScope` is satisfied for
  BOTH parties with NO new policy. The grant is checked against the live actor at render.

  ## Soft-delete adoption (ADR-040 §5.9, T37e) — `thread ▸cascade participant ▸cascade message`

  `ChatThread` is `archivable: true` and is the roster's cascade PARENT: archiving a thread
  cascades to archive its `ChatParticipant`s AND `ChatMessage`s at the SAME instant
  (`Samen.Scopes.Chat.CascadeArchive`, §5.4 — "neither is meaningful without its thread");
  restoring a thread restores exactly the same-instant-archived members
  (`Samen.Scopes.Chat.CascadeRestore`) — a participant/message archived independently stays
  archived (the same-instant match, T124-microsecond-safe per the CMS `page ▸cascade block`
  precedent this mirrors).

  `ChatParticipant` and `ChatMessage` are ALSO `archivable: true` — the archival SUBSTRATE
  (the `archived_at` column, the default-read exclusion, the `:archive`/`:restore`/`:archived`
  actions the cascade modules invoke) must exist on both for the cascade to have anything to
  set/match/restore, exactly as CMS's `Block` carries its own full substrate as the cascade
  TARGET of `page ▸cascade block`. The roster's ¶ footnote — "`chat.participant` ... has NO
  independent archive: it cascades with its thread only" — is enforced ONE LEVEL UP from the
  substrate, at POLICY: both resources carry an explicit
  `policy action([:archive, :restore]) do forbid_if(always()) end` (the same "reachable ONLY
  via the internal `authorize?: false` cascade call; any actor-based attempt is refused"
  posture `Samen.Scopes.Identity.Blueprint`'s pre-actor `:accept`/`:expire` transitions use) —
  a THREAD-level actor-driven archive/restore is possible; a PARTICIPANT/MESSAGE-level one is
  refused for any real actor and reachable only through the cascade's `authorize?: false`
  internal calls (which bypass policy checks entirely, same as every other cascade in this
  foundry). This is stricter than CMS's `Block`, which explicitly PERMITS actor-driven
  independent archiving — a deliberate scope difference the roster draws, not an oversight.
  """

  # ---------------------------------------------------------------------------
  # ChatThread — a conversation that may span two planes. Org-scoped. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_thread(module, otp_app, domain, repo, abbrev, participant_mod, message_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Chat.ChatThread — a conversation that may span the tenant↔operator plane boundary
        (ADR-012 §2.2). Org-scoped, owned by the TENANT org. No PII.

        `disclosure_mode` is the tenant-wide identity setting SNAPSHOTTED at thread create
        (`:masked | :tenant_wide | :initiator_opt_in`) so flipping the org setting later never
        retroactively exposes old threads. `context_ref` is an OPTIONAL `samen:<key>:<id>`
        object ref this thread is "about" (rendered via the SAME unfurl resolver).

        ## Soft-delete (ADR-040 §5.9, T37e)

        Archivable — and the cascade PARENT of `thread ▸cascade participant ▸cascade message`
        (§5.4): archiving a thread cascades to archive its `ChatParticipant`s and
        `ChatMessage`s at the same instant (`Samen.Scopes.Chat.CascadeArchive`); restoring a
        thread restores exactly the same-instant-archived members
        (`Samen.Scopes.Chat.CascadeRestore`) — a member archived independently stays archived.
        No action-name collision: no hand-authored `:archive`/`:restore`/`:archived` action
        exists here. `:archive`/`:restore`/`:archived` are TYPE-matched by the existing
        `action_type([:create, :update, :destroy])`/`action_type(:read)` policy blocks below
        (no separate policy needed — unlike CMS's Page/Post, this scope's generic policies are
        already type-based, not name-based).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_thread")
          repo(unquote(repo))
        end

        attributes do
          # Non-PII thread label ("Rate confirmation for load #4471").
          attribute(:subject, :string, public?: true)

          # A cross_plane thread has a SaaS participant; a tenant_internal one does not.
          attribute(:kind, :atom,
            public?: true,
            default: :cross_plane,
            constraints: [one_of: [:tenant_internal, :cross_plane]]
          )

          attribute(:status, :atom,
            public?: true,
            default: :open,
            constraints: [one_of: [:open, :closed]]
          )

          # The tenant-wide identity disclosure setting, snapshot at create (§5).
          attribute(:disclosure_mode, :atom,
            public?: true,
            default: :masked,
            constraints: [one_of: [:masked, :tenant_wide, :initiator_opt_in]]
          )

          # An OPTIONAL Samen object ref this thread is pinned to (opaque; not PII).
          attribute(:context_ref, :string, public?: true)
        end

        relationships do
          # The thread ▸cascade participant / thread ▸cascade message composition
          # (ADR-040 §5.4). Inverse of ChatParticipant/ChatMessage's `belongs_to :thread`.
          has_many :participants, unquote(participant_mod) do
            public?(true)
            destination_attribute(:thread_id)
          end

          has_many :messages, unquote(message_mod) do
            public?(true)
            destination_attribute(:thread_id)
          end
        end

        changes do
          # Thread ▸ {Participant, Message} same-instant cascade, both directions
          # (§5.4). See each cascade module's moduledoc for why this scope does not
          # use ash_archival's `archive_related` DSL option directly (timestamp
          # exactness + audit completeness — mirrors `Samen.Scopes.Cms.CascadeArchive`).
          #
          # `on:` defaults to `[:create, :update]` (Ash omits `:destroy` by default).
          # `:archive` IS a `:destroy`-type action, so CascadeArchive needs
          # `on: [:destroy]` explicitly or it silently never runs. CascadeRestore's
          # `:restore` is `:update`-typed, already covered by the default.
          change(Samen.Scopes.Chat.CascadeArchive, on: [:destroy])
          change(Samen.Scopes.Chat.CascadeRestore)
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
            forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ChatParticipant — 🔒 PII: full_name (vault :pii_name). The cross-plane grant carrier.
  # ---------------------------------------------------------------------------
  defmacro define_participant(module, otp_app, domain, repo, abbrev, thread_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Chat.ChatParticipant — membership + the cross-plane grant carrier 🔒 (ADR-012 §2.2).

        `party` (`:tenant | :operator`) records WHICH plane this participant acts from — the
        cross-plane seam. `full_name` is the participant's REAL identity (vault-routed PII);
        `handle` is the always-safe non-PII display label. `identity_shared` is the
        per-conversation initiator opt-in (§5 state 2). Org-scoped.

        ## Soft-delete (ADR-040 §5.9, T37e) — cascade child, NO independent archive

        Archivable (substrate only): carries `archived_at` + the `:archive`/`:restore`/
        `:archived` actions so `Samen.Scopes.Chat.CascadeArchive`/`CascadeRestore` (declared on
        `ChatThread`) have something to set/match/restore — but per the roster's ¶ footnote
        ("has NO independent archive: it cascades with its thread only"), the `policies` block
        below explicitly `forbid_if(always())`s any actor-driven `:archive`/`:restore` call;
        the ONLY path that ever archives/restores a participant is the thread's cascade,
        which runs `authorize?: false` (bypassing policy checks entirely, same as every other
        cascade in this foundry). An archived participant retires its `full_name` 🔒 vault
        token from default reads on BOTH planes, same as a live row's masking (§5.1) — the
        `full_name` masking-on-archived 3-proof (T37e) exercises exactly this row.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_participant")
          repo(unquote(repo))
        end

        attributes do
          # Which plane this participant acts from — the cross-plane seam (§2.3). Not PII.
          attribute(:party, :atom,
            public?: true,
            default: :tenant,
            constraints: [one_of: [:tenant, :operator]]
          )

          attribute(:principal_kind, :atom,
            public?: true,
            default: :user,
            constraints: [one_of: [:user, :agent, :operator_staff]]
          )

          # The referenced identity id (opaque; not PII).
          attribute(:principal_id, :string, public?: true)

          # A non-PII display handle — safe to render on either plane (§5.4).
          attribute(:handle, :string, public?: true)

          # The per-conversation initiator opt-in (§5 state 2). Default masked-floor.
          attribute(:identity_shared, :boolean, public?: true, default: false)

          attribute(:role, :atom,
            public?: true,
            default: :member,
            constraints: [one_of: [:member, :owner]]
          )

          attribute(:online_at, :utc_datetime, public?: true)
        end

        pii do
          vault(:pii_name)
          # Composite PII: full_name routes by vault name (no pii_ prefix on the column).
          # The participant's REAL identity, resolved clear/•••• per the chosen plane (§5.1).
          pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
          reveal(:reveal_participant)
        end

        relationships do
          belongs_to :thread, unquote(thread_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_participant, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_participant,
                label: :full_name
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        # A participant may only reference a same-org thread.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:thread]})
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # No independent archive (§5.4 ¶ footnote): reachable ONLY via the
          # thread's `authorize?: false` cascade calls (`Samen.Scopes.Chat.
          # CascadeArchive`/`CascadeRestore`); any actor-based attempt is refused
          # — the same "pre-actor / system transition" posture
          # `Samen.Scopes.Identity.Blueprint`'s `:accept`/`:expire` use. Placed
          # AFTER the broad `action_type` policy above so BOTH policies match
          # `:archive`/`:restore` (they are `:destroy`/`:update`-typed) — Ash
          # requires every matching policy to authorize, so this one alone
          # forbidding is enough to close the actor-driven path regardless of
          # ordering.
          policy action([:archive, :restore]) do
            forbid_if(always())
          end

          policy action(:reveal_participant) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ChatMessage — 🔒 PII: body (vault :pii_body). The Support.Message shape, verbatim.
  # ---------------------------------------------------------------------------
  defmacro define_message(module, otp_app, domain, repo, abbrev, thread_mod, participant_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Chat.ChatMessage — a single message 🔒 (ADR-012 §2.2). `body` is vault-routed PII
        (masked by default; plaintext only via the declared reveal action under a grant) —
        the EXACT `Support.Message` pii declaration, so the free-text vault routing is
        inherited verbatim, not reinvented.

        `refs` are the object refs parsed out of `body` AT SEND TIME (on the plaintext, before
        the body is vaulted) so unfurl never re-parses ciphertext (§4.2). Opaque strings; not
        PII. `sender_party` is denormalized (`:tenant | :operator`) for cheap broadcast render.

        ## Soft-delete (ADR-040 §5.9, T37e) — cascade child, NO independent archive

        Archivable (substrate only) — same shape as `ChatParticipant`: carries `archived_at` +
        the `:archive`/`:restore`/`:archived` actions so the thread's cascade
        (`Samen.Scopes.Chat.CascadeArchive`/`CascadeRestore`) has something to set/match/
        restore, but the `policies` block below `forbid_if(always())`s any actor-driven
        `:archive`/`:restore` — reachable only via the thread cascade's `authorize?: false`
        internal calls (§5.4 ¶ footnote: composition children have no independent archive).
        An archived message keeps its `body` 🔒 vault token and masks by plane exactly like a
        live row (§5.1) — trash, not erasure.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_message")
          repo(unquote(repo))
        end

        attributes do
          # Denormalized sender plane for cheap rendering / broadcast. Not PII.
          attribute(:sender_party, :atom,
            public?: true,
            default: :tenant,
            constraints: [one_of: [:tenant, :operator]]
          )

          attribute(:kind, :atom,
            public?: true,
            default: :message,
            constraints: [one_of: [:message, :system, :join, :leave]]
          )

          # The parsed object refs found in `body` at send time (opaque). Not PII.
          attribute(:refs, {:array, :string}, public?: true, default: [])
        end

        pii do
          vault(:pii_body)
          # Scalar PII: body is free-text. Column: pii_<abbrev>_body. Copied from
          # Support.Message — clear to the tenant, •••• to the operator, by construction.
          pii_attribute(:body, :string, vault: :pii_body)
          reveal(:reveal_message)
        end

        relationships do
          belongs_to :thread, unquote(thread_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :participant, unquote(participant_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_message, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_message,
                label: :body
              }

              if Samen.Reveal.grant_checker().granted?(ctx) do
                {:ok, %{status: "granted", subject_id: input.arguments.subject_id}}
              else
                {:error, :denied}
              end
            end)
          end
        end

        # A message may only reference a same-org thread/participant.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:thread, :participant]})
        end

        policies do
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # No independent archive (§5.4 ¶ footnote) — see ChatParticipant's
          # identical policy for the full rationale.
          policy action([:archive, :restore]) do
            forbid_if(always())
          end

          policy action(:reveal_message) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ChatDisclosureSetting — Tier-0 per-org config: expose participant identity to support.
  # Org-scoped. Admin-gated. No PII.
  # ---------------------------------------------------------------------------
  defmacro define_disclosure_setting(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Chat.ChatDisclosureSetting — a Tier-0 per-org config row (ADR-012 §5 state 3). One row
        per org. When `expose_identity_to_support` is ON, a cross-plane thread created for that
        org is stamped `disclosure_mode = :tenant_wide` at create time (a snapshot). Admin-gated
        writes. Org-scoped. No PII — it is an org-level policy flag.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_disclosure_setting")
          repo(unquote(repo))
        end

        attributes do
          # The tenant-wide consent flag — expose participant identity to SaaS support.
          attribute(:expose_identity_to_support, :boolean, public?: true, default: false)
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
end
