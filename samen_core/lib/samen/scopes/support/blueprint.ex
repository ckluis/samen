defmodule Samen.Scopes.Support.Blueprint do
  @moduledoc """
  Resource-definition macros for the Support scope (T3.6; ADR-004 blueprint).

  Objects: `ticket · conversation · message🔒 · agent🔒 · sla · macro · csat`
  (doc §"The inherited 80%" scope table).

  ## PII map (🔒)

  | Resource | Field      | Vault      | Column type                          |
  |----------|------------|------------|--------------------------------------|
  | message  | body       | :pii_body  | scalar (column: pii_smg_body)        |
  | agent    | full_name  | :pii_name  | composite (column: sag_full_name)    |
  | agent    | email      | :pii_email | scalar (column: pii_sag_email)       |

  ## The free-text-vs-composite tension on message.body

  `message.body` is declared as a **scalar `pii_attribute :body, :string, vault: :pii_body`**
  rather than a composite type (FullName/Emails/Phones). This is a deliberate tradeoff
  documented honestly here:

  - **Why scalar, not composite?** The body is free-form text — it cannot be modelled as a
    structured composite type (`Samen.Type.FullName` et al.), which are purpose-built for
    typed identity data (names, email lists, phone lists). Free-text conversation content
    is inherently untyped. Using a composite type would be wrong — it would impose structure
    (an email-list wrapper, say) on data that is just a string.

  - **Why vault at all?** Conversation bodies frequently contain PII (names, contact details,
    issue descriptions referencing personal information). The doc flags `message🔒` — the 🔒
    is correct and we honor it. The Samen verifiers key on the `pii do` declaration, not the
    column name, so `pii_attribute :body, :string, vault: :pii_body` is equally vault-routed:
    once declared, `pii_reads` and `no_plaintext_pii` enforce the *consequences* (no plaintext
    to a sink; no plaintext at rest / in any observability tier).

  - **Which check catches a FORGOTTEN 🔒 on body — precisely.** The gate enforces vault
    *consequences*, not the *presence* of the `pii do` declaration. Because `body` is NOT in
    the C4 `pii_classify` name-token list (see the pii_classify note below), `pii_classify`
    does NOT flag a de-vaulted body, and the resource-introspection verifiers key on the
    `pii do` block that a de-vault removes. So the authoritative red paths for a de-vaulted
    body are exactly two: (1) the `vault_declared_parity` verifier (C6, review fix F3.1), which
    reads the DB and fails closed on the leftover `pii_smg_body` column that no resource routes,
    and (2) this scope's `support_scope_vault_routing_test.exs` (the token/round-trip assertions).
    Do not read this moduledoc as "pii_classify guards body" — it does not.

  - **The honest residue:** scalar vault routing means the body is encrypted-at-rest as a
    single ciphertext blob. There is no granular field-level structure (you cannot reveal
    "just the phone number from the body" — you reveal the whole body). This is the right
    tradeoff for free-text: the body is a single unit of meaning; revealing it piecemeal
    makes no semantic sense. A richer approach (structured extraction + per-field vaulting)
    would require content classification that is out of scope here and documented as a
    posture-under-construction residue (same class as the DP/query-budget track in T4.5).

  - **pii_classify note:** `body` is NOT in the default heuristic PII-name-token list
    (`ssn·dob·mrn·cdl·tax_id·email·phone·address·…`), so C4 would not flag it automatically.
    We vault it explicitly because the field semantics are known at definition time. The
    `pii do` declaration is the authoritative gate, not the heuristic scanner.

  ## SLA breach detection — Oban cron

  SLA breach detection is a scheduled Oban worker
  (`Samen.Scopes.Support.SlaBreachWorker`) that runs every minute (configurable).
  It scans `stk_ticket` for rows where `stk_sla_breach_at <= now()` and
  `stk_breached = false`, marks them breached, and emits an `aud_event` row per
  ticket. The cron expression and queue are configurable at mount time.

  ## Tier-0 config rows

  `Macro` is the Support scope's Tier-0 config-row resource: one row per reusable
  response macro (canned reply) per org. Agents use macros to respond quickly to
  common ticket types without forking the product.

  `Sla` is also a Tier-0 config resource: per-org SLA policies (first-response /
  resolution targets per ticket priority). The actual breach detection fires against
  `stk_ticket.stk_sla_breach_at` (a computed deadline column set from the SLA policy
  at ticket-create time).

  ## Storage-name discipline

  Every column is `<abbrev>_<name>` (self-qualifying storage). PII scalar fields carry
  the `pii_` prefix FIRST (`pii_<abbrev>_<name>`): e.g. `pii_sag_email`, `pii_smg_body` —
  matching the canonical shape the `MaterializePii` transformer emits and the PII-map table
  above. The public API/catalog only ever sees the logical name.
  """

  # ---------------------------------------------------------------------------
  # Ticket — the top-level support ticket. Org-scoped. No PII.
  # Carries an SLA deadline (`sla_breach_at`) set at create time.
  # ---------------------------------------------------------------------------
  defmacro define_ticket(
             module,
             otp_app,
             domain,
             repo,
             abbrev,
             sla_mod,
             conversation_mod,
             csat_survey_token_mod,
             csat_mod
           ) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Support.Ticket — a support ticket (doc scope table `ticket`). The root
        object in the Support scope. Org-scoped. No PII in the ticket header —
        the conversation/message objects hold the content (message body is 🔒).

        Carries `sla_breach_at` (the computed SLA deadline) and `breached`
        (set to `true` by the `Samen.Scopes.Support.SlaBreachWorker` cron when
        the deadline passes). Linked to an optional `Sla` config row.

        ## Tags (F4/T46 — migrated off this resource)

        Ticket previously carried a bespoke `tags` (`{:array, :string}`) column.
        F4/T46 migrated every existing ticket's tags to the generic
        `Samen.Scopes.Tags` `Tag`/`Tagging` mechanism (org-scoped, polymorphic,
        archivable Tag) and DROPPED this column
        (`MigrateTicketTagsToTagScope` — a contract-phase, zero-drop, set-based
        copy; see that migration's moduledoc). Reading a ticket's tags now goes
        through `Samen.Web.Support.Reads.ticket_tag_names/3` /
        `Samen.Web.Tags.names_for/4`, anchored by `subject_key =
        Samen.Web.ObjectRef.Catalog.key_for(Ticket)` (each host's OWN derived
        key — `"support.ticket"` on driftwood/pawchart/samen_web,
        `"support_scope.ticket"` on demo).

        ## Soft-delete (ADR-040 §5.9, T37f; reconciled T125) — the cascade PARENT of
        ## `ticket ▸cascade conversation ▸cascade message`

        Archivable — and the roster's cascade PARENT (§5.4, the ADR's own canonical
        worked example): archiving a ticket cascades to archive its `Conversation`s
        AND their `Message`s at the SAME instant
        (`Samen.Scopes.Support.CascadeArchive`, mirroring `Samen.Scopes.Cms.
        CascadeArchive`/`Samen.Scopes.Chat.CascadeArchive`, generalized one level
        deeper: ticket → conversation is direct, conversation → message is direct,
        so the cascade sweeps conversations by `ticket_id` and then messages by
        `conversation_id` under those same conversations); restoring a ticket
        restores exactly the same-instant-archived members
        (`Samen.Scopes.Support.CascadeRestore`).

        **POSTURE (T125, ADR-040 §5.4/§5.9 reconciled — INDEPENDENT-ARCHIVABLE
        CHILDREN EVERYWHERE):** `Conversation` and `Message` are ORDINARY
        independently-archivable composition children, same as CMS's `Block` — an
        authorized (org-scoped, role >= member) actor CAN archive/restore either
        directly, and the ticket's cascade still sweeps every still-live
        conversation/message at ticket-archive time. (Pre-T125, this scope read the
        roster's `▸cascade` arrows — with no internal comma, superficially unlike
        CMS's comma-separated `page ▸cascade block` — as implying a cascade-only
        lock; the T37f verifier adjudicated that reading a misreading of pure list
        punctuation, see `_orch/verify/T37f-verdict.json` finding F3, and ADR-040
        §5.4/§5.9 now states the default explicitly: composition-cascade children
        are independently-archivable unless individually footnoted, and
        `conversation`/`message` carry no such footnote.) See `Conversation`'s and
        `Message`'s own moduledocs.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_ticket")
          repo(unquote(repo))

          # T60: the atomic dedupe backstop for chat offline-escalation — a partial-
          # unique index on `(org_id, external_id) WHERE external_id IS NOT NULL`. It
          # makes a CONCURRENT double-escalation of the SAME chat structurally
          # impossible: exactly one insert wins; the loser's insert raises this named
          # constraint, which `unique_index_names/1` (below, abbrev-parameterised so it
          # covers EVERY host uniformly) maps to a clean `{:error, _}` (NOT a raw
          # Postgrex abort, NOT a fabricated success) so the capability re-reads the
          # winner and returns `:already_escalated`. NORMAL inbound/support tickets carry
          # `external_id == nil` and are UNCONSTRAINED by the partial predicate — no
          # regression to the T59 inbound flow.
          #
          # `custom_indexes` is the FRAMEWORK-LEVEL declaration of this index (single
          # source of truth). NB: this foundry emits schema as hand-written/templated DDL
          # via `Samen.Migration` (NOT `ash_postgres.generate_migrations`), so the index
          # is REALISED for every adopter by the framework-controlled operator-mount
          # template (`priv/templates/m_mount_operator_scopes.eex` — every generated app)
          # plus each existing host's migration (demo/driftwood/pawchart). The name here,
          # the template, `unique_index_names`, and each migration are kept identical.
          custom_indexes do
            index([:org_id, :external_id],
              unique: true,
              name: "#{unquote(abbrev)}_ticket_chat_dedupe_idx",
              where: "#{unquote(abbrev)}_external_id IS NOT NULL"
            )
          end

          unique_index_names([
            {[:org_id, :external_id], "#{unquote(abbrev)}_ticket_chat_dedupe_idx"}
          ])
        end

        attributes do
          attribute(:subject, :string, public?: true, allow_nil?: false)
          attribute(:status, :atom,
            public?: true,
            default: :open,
            constraints: [one_of: [:open, :pending, :on_hold, :resolved, :closed]]
          )
          attribute(:priority, :atom,
            public?: true,
            default: :normal,
            constraints: [one_of: [:low, :normal, :high, :urgent]]
          )
          # SLA deadline — set at create time from the linked Sla policy. The
          # SlaBreachWorker cron scans for tickets where sla_breach_at <= now()
          # and breached = false.
          attribute(:sla_breach_at, :utc_datetime, public?: true)
          attribute(:breached, :boolean, public?: true, default: false)
          attribute(:resolved_at, :utc_datetime, public?: true)
          attribute(:closed_at, :utc_datetime, public?: true)
          attribute(:custom, :map, public?: true)
          # Opaque external ID (Zendesk-style integration reference). Not PII.
          attribute(:external_id, :string, public?: true)
        end

        relationships do
          belongs_to :sla, unquote(sla_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end

          # The ticket ▸cascade conversation composition (§5.4). Inverse of
          # Conversation's `belongs_to :ticket`. Used by
          # `Samen.Scopes.Support.CascadeArchive`/`CascadeRestore` to resolve the
          # Conversation resource module, and by the scope's §5.5 relationship-load
          # leak red test.
          has_many :conversations, unquote(conversation_mod) do
            public?(true)
            destination_attribute(:ticket_id)
          end
        end

        # F3.5 same-org FK: a ticket may only reference a same-org sla.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:sla]})

          # Ticket ▸ {Conversation, Message} same-instant cascade (§5.4). See
          # `Samen.Scopes.Support.CascadeArchive`/`CascadeRestore` moduledocs for why
          # this scope does not use ash_archival's `archive_related` DSL option
          # directly (timestamp exactness + audit completeness — mirrors
          # `Samen.Scopes.Cms.CascadeArchive`/`Samen.Scopes.Chat.CascadeArchive`).
          #
          # `on:` defaults to `[:create, :update]` (Ash omits `:destroy` by default).
          # `:archive` IS a `:destroy`-type action, so CascadeArchive needs
          # `on: [:destroy]` explicitly or it silently never runs. CascadeRestore's
          # `:restore` is `:update`-typed, already covered by the default.
          change(Samen.Scopes.Support.CascadeArchive, on: [:destroy])
          change(Samen.Scopes.Support.CascadeRestore)

          # I6 (spec §I6, T79) — CSAT loop trigger: a ticket transitioning INTO
          # `:resolved` sets `resolved_at` (part of THIS atomic write — closes a
          # pre-existing gap, `resolved_at` was never actually set by any
          # sanctioned write path before this task) and, best-effort AFTER the
          # write's transaction commits, mints + dispatches a CSAT survey. See
          # `Samen.Scopes.Support.CsatSurveyDispatch` moduledoc for why the send
          # rides `after_transaction` (never `after_action`, which runs INSIDE
          # the transaction and would hold it open across a real network send).
          change(
            {Samen.Scopes.Support.CsatSurveyDispatch,
             csat_survey_token: unquote(csat_survey_token_mod), csat: unquote(csat_mod)}
          )
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
  # Conversation — a thread attached to a ticket. Org-scoped. No PII.
  # A ticket may have multiple conversations (internal/external channels).
  # ---------------------------------------------------------------------------
  defmacro define_conversation(module, otp_app, domain, repo, abbrev, ticket_mod, message_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Support.Conversation — a conversation thread on a ticket (doc scope table
        `conversation`). Groups a sequence of messages. Org-scoped. No PII in the
        conversation record itself — message bodies carry the 🔒 PII.

        ## Soft-delete (ADR-040 §5.9, T37f; reconciled T125) — cascade child,
        ## INDEPENDENTLY-ARCHIVABLE (posture A)

        Archivable — carries `archived_at` + the `:archive`/`:restore`/`:archived`
        actions so `Samen.Scopes.Support.CascadeArchive`/`CascadeRestore` (declared on
        `Ticket`) have something to set/match/restore, and also the cascade PARENT one
        level down for `Message` (`conversation ▸cascade message`). Per T125's
        reconciliation of ADR-040 §5.4/§5.9 (posture A — independent-archivable
        children everywhere, matching CMS), a `Conversation` is ALSO an ORDINARY
        independently-archivable resource: an authorized (org-scoped, role >= member)
        actor may call `:archive`/`:restore` on it directly — no
        `forbid_if(always())` lock. The ticket's cascade
        (`Samen.Scopes.Support.CascadeArchive`/`CascadeRestore`, `authorize?: false`)
        still sweeps every still-live conversation at ticket-archive time
        (same-instant); a conversation archived independently stays archived across a
        later ticket restore (the same-instant match, §5.4) — this is the SAME
        posture CMS's `Block` has always had, and the SAME posture chat's `ChatMessage`
        was reconciled to under T125 (chat's `ChatParticipant` is the ADR's ONE
        documented exception — the cross-plane grant carrier — and is unaffected by
        this reconciliation).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_conversation")
          repo(unquote(repo))
        end

        attributes do
          attribute(:channel, :atom,
            public?: true,
            default: :email,
            constraints: [one_of: [:email, :chat, :api, :internal]]
          )
          attribute(:status, :atom,
            public?: true,
            default: :open,
            constraints: [one_of: [:open, :closed]]
          )
          # Not PII — a computed subject summarising the conversation context.
          attribute(:subject, :string, public?: true)
        end

        relationships do
          belongs_to :ticket, unquote(ticket_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          # The conversation ▸cascade message composition (§5.4), one level down
          # from the ticket ▸cascade conversation cascade. Inverse of Message's
          # `belongs_to :conversation`. Used by
          # `Samen.Scopes.Support.CascadeArchive`/`CascadeRestore` to resolve the
          # Message resource module.
          has_many :messages, unquote(message_mod) do
            public?(true)
            destination_attribute(:conversation_id)
          end
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])
        end

        # F3.2 same-org FK: a conversation may only reference a same-org ticket.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:ticket]})
        end

        policies do
          policy action_type(:read) do
            authorize_if(Samen.Policy.OrgScope)
          end

          # T125 (ADR-040 §5.4/§5.9 reconciled, posture A): NO
          # `forbid_if(always())` lock here — a Conversation is an ordinary,
          # independently-archivable composition child, matching CMS's `Block`
          # and chat's `ChatMessage`. `:archive`/`:restore` are
          # `:destroy`/`:update`-typed, so they are already covered by this
          # broad `action_type` policy (OrgScope + role >= member) — no
          # separate policy needed.
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
  # Message — 🔒 PII: body (vault :pii_body). Org-scoped.
  # Free-text conversation content. The body is scalar-vaulted (a single
  # ciphertext blob). See the blueprint moduledoc for the free-text-vs-composite
  # tension documentation.
  # ---------------------------------------------------------------------------
  defmacro define_message(module, otp_app, domain, repo, abbrev, conversation_mod, agent_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Support.Message — a single message in a conversation 🔒 (doc scope table
        `message🔒`).

        `body` is vault-routed PII (masked by default; plaintext only via the
        declared reveal action under a grant). The body is a free-text field (a
        single ciphertext blob — see the blueprint moduledoc for the tension between
        free-text and composite vault routing). Org-scoped.

        ## Soft-delete (ADR-040 §5.9, T37f; reconciled T125) — cascade child,
        ## INDEPENDENTLY-ARCHIVABLE (posture A)

        Archivable — same shape as `Conversation`: carries `archived_at` + the
        `:archive`/`:restore`/`:archived` actions so the ticket's cascade
        (`Samen.Scopes.Support.CascadeArchive`/`CascadeRestore`) has something to
        set/match/restore. Per T125's reconciliation of ADR-040 §5.4/§5.9 (posture
        A), a `Message` is ALSO an ORDINARY independently-archivable resource: an
        authorized (org-scoped) actor may call `:archive`/`:restore` on it directly
        — no `forbid_if(always())` lock, matching CMS's `Block` and chat's
        `ChatMessage`. An archived message keeps its `body` 🔒 vault token and masks
        by plane exactly like a live row (§5.1) — trash, not erasure.
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
          # Sender type is a bounded enum — NOT PII (it classifies direction, not identity).
          attribute(:sender_type, :atom,
            public?: true,
            default: :customer,
            constraints: [one_of: [:customer, :agent, :system]]
          )
          # Opaque sender ID (a reference to an agent or external ID). Not PII.
          attribute(:sender_id, :uuid, public?: true)
          attribute(:message_type, :atom,
            public?: true,
            default: :reply,
            constraints: [one_of: [:reply, :note, :escalation, :resolution]]
          )
          attribute(:attachments, {:array, :string}, public?: true, default: [])
          attribute(:created_via, :atom,
            public?: true,
            default: :web,
            constraints: [one_of: [:web, :api, :email, :chat, :macro]]
          )
        end

        pii do
          vault(:pii_body)
          # Scalar PII: body is free-text. Column carries the pii_ prefix: pii_smg_body.
          # See blueprint moduledoc §"The free-text-vs-composite tension".
          # Scalar PII: body is free-text. Column name: pii_<abbrev>_body (e.g. pii_smg_body).
          pii_attribute(:body, :string, vault: :pii_body)
          reveal(:reveal_message)
        end

        relationships do
          belongs_to :conversation, unquote(conversation_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :agent, unquote(agent_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
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

        # F3.2 same-org FK: a message may only reference a same-org conversation/agent.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:conversation, :agent]})
        end

        policies do
          # T125 (ADR-040 §5.4/§5.9 reconciled, posture A): NO
          # `forbid_if(always())` lock here — a Message is an ordinary,
          # independently-archivable composition child. `:archive`/`:restore`
          # are already covered by this broad `action_type` policy
          # (OrgScope-gated) — no separate policy needed.
          policy action_type([:read, :create, :update, :destroy]) do
            authorize_if(Samen.Policy.OrgScope)
          end

          policy action(:reveal_message) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Agent — 🔒 PII: full_name (vault :pii_name), email (vault :pii_email).
  # A support agent identity record. Org-scoped.
  # ---------------------------------------------------------------------------
  defmacro define_agent(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Support.Agent — a support agent 🔒 (doc scope table `agent🔒`).

        `full_name` (composite) and `email` (scalar) are vault-routed PII (masked by
        default; plaintext only via the declared reveal action under a grant). Org-scoped.
        Carries a bounded `role` (`:agent` / `:admin` / `:supervisor`), a `status`, and
        an opaque `external_id` for helpdesk integrations.

        ## Soft-delete (ADR-040 §5.9, T37f)

        Archivable — a standalone roster item (no cascade arrow in the roster: `agent,
        sla, macro` are plain comma-separated entries, unlike the `ticket ▸cascade
        conversation ▸cascade message` chain). No cascade to/from any other resource:
        archiving an agent leaves `Message.agent`/`Csat.agent` references live but
        pointing at a hidden row (§5.4 default: no cascade) — an archived agent keeps
        its vaulted `full_name`/`email` tokens and masks by plane exactly like a live
        row (§5.1); the operator/support UI shows the "archived agent" affordance
        (T37h). This is the roster's named masking-on-archived target (INV-1).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_agent")
          repo(unquote(repo))
        end

        attributes do
          # A safe, non-PII display handle (like Identity.User.handle).
          attribute(:handle, :string, public?: true)
          attribute(:status, :atom,
            public?: true,
            default: :active,
            constraints: [one_of: [:active, :inactive, :suspended]]
          )
          attribute(:role, :atom,
            public?: true,
            default: :agent,
            constraints: [one_of: [:agent, :supervisor, :admin]]
          )
          # Opaque external ID for helpdesk integrations. Not PII.
          attribute(:external_id, :string, public?: true)
          attribute(:timezone, :string, public?: true)
          attribute(:custom, :map, public?: true)
        end

        pii do
          vault(:pii_name)
          vault(:pii_email)
          # Composite PII: full_name routes by vault name (no pii_ prefix on column).
          pii_attribute(:full_name, Samen.Type.FullName, vault: :pii_name)
          # Scalar PII: email carries the pii_ prefix (pii_sag_email).
          pii_attribute(:email, :string, vault: :pii_email)
          reveal(:reveal_agent)
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          action :reveal_agent, :map do
            argument(:actor_id, :string, allow_nil?: false)
            argument(:subject_id, :string, allow_nil?: false)

            run(fn input, _ctx ->
              ctx = %Samen.Reveal.Context{
                actor: input.arguments.actor_id,
                subject_id: input.arguments.subject_id,
                resource: __MODULE__,
                action: :reveal_agent,
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

          policy action(:reveal_agent) do
            authorize_if(always())
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Sla — Tier-0 config rows: per-org SLA policies. Org-scoped. Admin-gated.
  # Defines response + resolution targets (in minutes) per priority level.
  # The SLA breach detection cron reads sla_id from tickets to infer targets.
  # ---------------------------------------------------------------------------
  defmacro define_sla(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Support.Sla — Tier-0 config rows (doc scope table `sla`; malleability
        ladder §7 "config rows cover ~70%"). One row per SLA policy per org.
        Defines first-response and resolution targets (in minutes) per priority.
        Admin-gated writes. Org-scoped.

        Tickets link to an `Sla` row (`stk_sla_id`). At ticket create time the
        host sets `stk_sla_breach_at = inserted_at + resolve_minutes`. The
        `Samen.Scopes.Support.SlaBreachWorker` cron fires every minute and marks
        breached tickets.

        ## Soft-delete (ADR-040 §5.9, T37f)

        Archivable — a standalone roster item, no cascade. Archiving an SLA policy
        leaves any `Ticket.sla` reference live but pointing at a hidden row (§5.4
        default: no cascade) — new tickets simply cannot select an archived SLA
        policy; existing tickets keep their `sla_id` FK untouched.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_sla")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:label, :string, public?: true)
          # Targets in minutes — platform-agnostic.
          attribute(:first_response_minutes, :integer, public?: true, default: 60)
          attribute(:resolve_minutes, :integer, public?: true, default: 480)
          attribute(:priority, :atom,
            public?: true,
            default: :normal,
            constraints: [one_of: [:low, :normal, :high, :urgent]]
          )
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
  # Macro — Tier-0 config rows: reusable canned responses per org.
  # Org-scoped. Admin-gated writes.
  # ---------------------------------------------------------------------------
  defmacro define_macro(module, otp_app, domain, repo, abbrev) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Support.Macro — Tier-0 config rows (doc scope table `macro`). One row per
        reusable response macro (canned reply) per org. Agents use macros to reply
        quickly to common ticket types without forking the product. Admin-gated writes.
        Org-scoped.

        ## Non-PII classification

        The `body_template` field is a template string authored by operators — it is
        NOT subject personal data. It is analogous to `CmsScope.SeoMeta.description`
        (authored content, not subject identity). A host that uses macro bodies as
        templates for message sends must ensure the expanded body routes through the
        vault (the message body is 🔒).

        ## Soft-delete (ADR-040 §5.9, T37f)

        Archivable — a standalone roster item, no cascade. Archiving a macro simply
        removes it from the agent-facing canned-response picker; no other resource
        references a macro by FK, so there is nothing for it to leak via relationship
        load or aggregate (a documented, honest scope note — same class as
        primitives' `File`/`Webhook`/`FeatureFlag`, T37e).
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev),
          archivable: true

        postgres do
          table("#{unquote(abbrev)}_macro")
          repo(unquote(repo))
        end

        attributes do
          attribute(:name, :string, public?: true, allow_nil?: false)
          attribute(:description, :string, public?: true)
          attribute(:body_template, :string, public?: true)
          attribute(:tags, {:array, :string}, public?: true, default: [])
          attribute(:enabled, :boolean, public?: true, default: true)
          attribute(:category, :string, public?: true)
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
  # Csat — customer satisfaction survey response. Org-scoped. No PII.
  # The respondent is identified by opaque ticket/conversation IDs only.
  # ---------------------------------------------------------------------------
  defmacro define_csat(module, otp_app, domain, repo, abbrev, ticket_mod, agent_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Support.Csat — a customer satisfaction survey response (doc scope table
        `csat`). Org-scoped. No PII — the respondent is identified only by opaque
        `ticket_id` and `agent_id` references. The `comments` field contains the
        verbatim response text.

        ## Non-PII classification for comments

        `csat_comments` is a free-text field. It COULD contain PII (a customer might
        write their name in a comment). However, the **platform design decision** is:

        1. The primary PII carrier (the message exchange) is already vaulted on Message.
        2. CSAT is an aggregate metric surface. Treating comments as vault-routed would
           break aggregation and analytics (you cannot AVG() over ciphertexts).
        3. The doc does NOT flag csat as 🔒 in the scope table.

        Therefore `csat_comments` is NOT vault-routed. This is documented as an honest
        residue: a host that collects sensitive csat comments should consider vaulting them
        at the product layer. The platform flags this via a registered non_pii! override
        (the `Demo.SupportScope.NonPiiSetup` module) with distinct-reviewer sign-off,
        consistent with the mask-unknown-by-default discipline (D9). The `pii_classify`
        verifier (C4) does not flag "comments" as a likely-PII name; but the explicit
        registration is good practice for an auditor trail.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_csat")
          repo(unquote(repo))
        end

        attributes do
          attribute(:score, :integer, public?: true, allow_nil?: false)
          attribute(:comments, :string, public?: true)
          attribute(:channel, :atom,
            public?: true,
            default: :email,
            constraints: [one_of: [:email, :chat, :api]]
          )
          attribute(:responded_at, :utc_datetime, public?: true)
        end

        relationships do
          belongs_to :ticket, unquote(ticket_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :agent, unquote(agent_mod) do
            public?(true)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        # F3.5 same-org FK: a csat may only reference a same-org ticket/agent.
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:ticket, :agent]})
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
  # CsatSurveyToken — I6 (spec §I6, T79): the single-use, expiring, hashed-at-
  # rest secret that closes the CSAT loop's request→response half. Org-scoped
  # (unlike Identity.AuthToken, which is org-less — a CSAT survey is always
  # about ONE org's ticket). Mirrors AuthToken's ADR-035 §4.2 shape
  # (token_digest / expires_at / consumed_at, default-deny policy, one atomic
  # `:consume` action) rather than inventing a new single-use-token mechanism —
  # see `Samen.Scopes.Support.CsatSurvey` moduledoc for why `Samen.Auth.
  # TokenConsume` itself isn't reused verbatim (it's hardcoded to AuthToken's
  # `context`-enum shape).
  # ---------------------------------------------------------------------------
  defmacro define_csat_survey_token(module, otp_app, domain, repo, abbrev, ticket_mod, agent_mod) do
    quote do
      defmodule unquote(module) do
        @moduledoc """
        Support.CsatSurveyToken — a single-use, expiring, hashed-at-rest CSAT
        survey link (I6, T79). No PII: the token itself is an opaque 256-bit
        secret; `ticket`/`agent` are opaque refs. `sent_at` is set ONLY when
        `Samen.Delivery.Chokepoint.send/2` genuinely returns `{:ok, _}` — NEVER
        optimistically at mint time (fail-honest: a blocked/suppressed send
        leaves `sent_at` nil, an honest "minted, not confirmed sent" state, so
        an operator inspecting this table can tell a genuinely-delivered survey
        from one that never left the chokepoint).

        Default-deny policy (same posture as `Identity.AuthToken`) — reachable
        ONLY through `Samen.Scopes.Support.CsatSurvey`'s governed
        mint/preview/respond functions, never a raw Ash bypass policy.
        """
        use Samen.Resource,
          otp_app: unquote(otp_app),
          domain: unquote(domain),
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          abbrev: unquote(abbrev)

        postgres do
          table("#{unquote(abbrev)}_csat_survey_token")
          repo(unquote(repo))
        end

        attributes do
          # SHA-256 digest of the 32-random-byte raw token (`Samen.Auth.
          # TokenMint.digest/1`). One-way; the raw token is never stored — it
          # exists only in the transient, non-persisted email content
          # `Samen.Scopes.Support.CsatSurvey.send_survey/3` renders.
          attribute(:token_digest, :string, public?: false, allow_nil?: false)
          attribute(:expires_at, :utc_datetime, public?: false, allow_nil?: false)
          attribute(:consumed_at, :utc_datetime, public?: false, allow_nil?: true)
          attribute(:sent_at, :utc_datetime, public?: false, allow_nil?: true)
        end

        relationships do
          belongs_to :ticket, unquote(ticket_mod) do
            public?(false)
            attribute_type(:uuid)
            allow_nil?(false)
          end

          belongs_to :agent, unquote(agent_mod) do
            public?(false)
            attribute_type(:uuid)
            allow_nil?(true)
          end
        end

        # F3.5 same-org FK: a survey token may only reference a same-org
        # ticket/agent. Scoped to `:create` ONLY (`on: [:create]`) — `:consume`/
        # `:mark_sent` never touch `ticket_id`/`agent_id` (SameOrgFk would be a
        # runtime no-op for them per its own `fk_being_written?/2` guard), but
        # leaving it resource-wide would make BOTH actions fail Ash's static
        # `require_atomic?` check (SameOrgFk's read-then-compare shape cannot be
        # proven atomic-compatible), which collides with the `strategy:
        # [:atomic]` `Ash.bulk_update!/4` call `Samen.Scopes.Support.CsatSurvey`
        # forces on `:consume` (the single-use-consume discipline's whole
        # point).
        changes do
          change({Samen.Policy.SameOrgFk, relationships: [:ticket, :agent]}, on: [:create])
        end

        actions do
          defaults([:read, :destroy, create: :*, update: :*])

          # The ONE atomic single-use consume action (mirrors `Identity.
          # AuthToken`'s `:consume`) — `accept []`, the caller supplies
          # `consumed_at` as an argument, force-set via `set_attribute`, never
          # accepted as raw changeset input. Called ONLY through
          # `Samen.Scopes.Support.CsatSurvey`'s own atomic
          # `Ash.bulk_update!/4` + `strategy: [:atomic]` consume (the SAME
          # single-`UPDATE...WHERE...RETURNING` discipline `Samen.Auth.
          # TokenConsume` uses, hand-fitted to this resource's columns).
          update :consume do
            accept([])
            argument(:consumed_at, :utc_datetime, allow_nil?: false)
            change(set_attribute(:consumed_at, arg(:consumed_at)))
          end

          # Set ONLY after a genuine `{:ok, _}` from the delivery chokepoint —
          # see the moduledoc's fail-honest `sent_at` note.
          update :mark_sent do
            accept([])
            argument(:sent_at, :utc_datetime, allow_nil?: false)
            change(set_attribute(:sent_at, arg(:sent_at)))
          end
        end

        policies do
          # Same posture as Identity.AuthToken: no actor-reachable read/write.
          # The governed `Samen.Scopes.Support.CsatSurvey` module calls in with
          # `authorize?: false` — a public LiveView NEVER touches this
          # resource's Ash actions directly.
          policy always() do
            forbid_if(always())
          end
        end
      end
    end
  end
end
