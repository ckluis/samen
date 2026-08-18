defmodule Samen.AI.SupportReplyDraft do
  @moduledoc """
  `Samen.AI.SupportReplyDraft` — the D5 AI-support-operator DRAFT resource (ADR-043 §6.3, T70).

  The AI support operator (`Samen.AI.SupportOperator`) DRAFTS a reply to an inbound support
  item and persists it as one of these rows — grounded on masked-path data through the T68
  intelligence verbs, so the `:body`/`:subject` it stores are AI-composed text that already
  passed the `Samen.AI.Chokepoint` egress scrub (no plaintext vault value, no `vt_*` token).
  A draft is **structurally unable to send**: it carries no send path of its own. The ONLY
  route from a draft to `Samen.Delivery.Chokepoint.send/2` is an E3 approval decided by a
  human who is never the requester (`Samen.AI.SupportOperator.ReplyHandler`, ADR-043 §6.3).

  ## Why this is safe to persist (INV-1)

  Unlike an approval row (which stores NO inputs, §4.4), a draft legitimately stores the
  drafted reply — because that reply is the AI operator's OWN masked output, not subject
  PII. The recipient is referenced by TOKEN only (`to_subscriber_id`, a subscriber UUID —
  the real email is revealed from the vault at `deliver/2` time under the send plane, never
  stored here, the `Samen.Delivery.Message` token-only convention). `inbound_ref` is a
  bounded object-ref string. There is therefore NO vault-routed column on this resource
  (`vault_declared_parity` has nothing to discover, and the no-PII-at-rest invariant holds
  by construction).

  ## Status lifecycle (framework-first, ≈0-LOC vertical adoption — INV-5)

  `:draft → :sent` (only via the approve handler's `:mark_sent`, inside the E3 decision
  transaction) or `:draft → :discarded` (the requester/approver withdraws, or a rejection).
  `:edit_body` lets a human amend the drafted reply before approving (ADR-043 §6.3
  "edit-then-approve sends the edited body"). Org-scoped + catalog-registered like every
  `use Samen.Resource`; a vertical adopts the whole operator by mounting `Samen.AI.Domain`.
  """
  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.AI.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sas"

  postgres do
    table("ai_support_reply_draft")
    repo(Application.compile_env(:samen_core, :samen_ai_support_reply_draft_repo, SamenCore.TestRepo))
  end

  attributes do
    # The recipient subscriber TOKEN (a UUID). The real email is revealed from the vault at
    # delivery time on the send plane (the `Samen.Delivery.Message` token-only convention) —
    # never stored on this draft row.
    attribute(:to_subscriber_id, :uuid, public?: true, allow_nil?: false)

    # The inbound support item this reply answers — a bounded object-ref string
    # ("samen:<abbrev>:<id>"), token-safe (never the item's content).
    attribute(:inbound_ref, :string, public?: true)

    # AI-composed reply text. NOT vault-routed: it is the operator's OWN masked output
    # (already through the chokepoint egress scrub), not subject PII.
    attribute(:subject, :string, public?: true)
    attribute(:body, :string, public?: true, allow_nil?: false)

    # The AI service principal that drafted this (bounded id string, audit trail). The
    # operator's principal is NEVER a decider (ADR-043 §6.3) — the engine's distinct-party
    # check refuses `decided_by == requested_by`, so a self-approval by this principal fails.
    attribute(:requested_by, :string, public?: true)

    # T152 honesty provenance (PP-16): whether the draft body came from a keyless/deterministic
    # (SIMULATED) provider rather than a real model. Threaded verbatim from the composing
    # `%Samen.AI.Completion{}.simulated` at `:draft` create by `Samen.AI.SupportOperator`, so the
    # tenant Support-draft LIST (which re-reads persisted rows) can render the loud "SIMULATED —
    # not a real model" badge on a stored simulated draft. NOT vault-routed (a boolean provenance
    # flag, not subject PII). Defaults `false` (a real-model draft) — fail-honest.
    attribute(:simulated, :boolean,
      public?: true,
      allow_nil?: false,
      default: false
    )

    # Lifecycle. `writable?: false` keeps it out of every action's default accept — only the
    # transition changes below ever set it, so a draft can never be marked `:sent` except
    # through the approve handler's `:mark_sent` action.
    attribute(:status, :atom,
      public?: true,
      allow_nil?: false,
      default: :draft,
      writable?: false,
      constraints: [one_of: [:draft, :sent, :discarded]]
    )
  end

  actions do
    defaults([:read])

    create :draft do
      description("Persist an AI-composed support reply draft (status :draft).")
      accept([:org_id, :to_subscriber_id, :inbound_ref, :subject, :body, :requested_by, :simulated])
    end

    # A human amends the drafted reply before approving (ADR-043 §6.3). Editing never sends.
    update :edit_body do
      accept([:subject, :body])
      require_atomic?(false)
    end

    # Driven ONLY by `Samen.AI.SupportOperator.ReplyHandler.on_approve/2`, inside the E3
    # decision transaction, AFTER a successful `Samen.Delivery.Chokepoint.send/2`.
    update :mark_sent do
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :sent))
    end

    # A rejection / withdrawal discards the draft; no send ever happens.
    update :discard do
      accept([])
      require_atomic?(false)
      change(set_attribute(:status, :discarded))
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
