import Config

config :samen_core, SamenCore.TestRepo,
  username: System.get_env("USER") || "postgres",
  password: "",
  hostname: "localhost",
  database: "samen_core_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  # pool_size 20 + queue slack: verify_vault_declared_parity opens direct
  # Postgrex connections outside the sandbox for DDL; under an unlucky seed the
  # concurrent checkout pressure hit the 4s queue timeout ~1-in-8 full runs
  # (WS-B B9 gate F1). Not a correctness issue — headroom kills the flake.
  pool_size: 20,
  queue_target: 200,
  queue_interval: 2_000

config :logger, level: :warning

# Gate-1 F1 red-path hook: the empty-registry exit-code test runs the pii_reads
# task in a child OS process with SAMEN_EMPTY_ASH_DOMAINS=1, which clears the
# discovered domains so the built PII registry is empty. This lets the test prove
# the task exits 1 (fail-closed) on a vacuous check rather than exit 0.
if System.get_env("SAMEN_EMPTY_ASH_DOMAINS") == "1" do
  config :samen_core, ash_domains: []
end

# test_helper.exs owns the Repo lifecycle (storage_up + migrate before connect).
config :samen_core, start_repo?: false

# Shared default repo for the samen_core verifiers/runtime that resolve a repo from
# :verify_repo (migrations, no_plaintext_pii, erasure/dsar, files audit, the workers, …).
config :samen_core, :verify_repo, SamenCore.TestRepo

# T1.7 erasure: the repo backing the non_pii! registry + erasure reports. The
# reveal-grant audit log the erasure path writes to uses :reveal_grant_repo
# (already configured in config/config.exs).
config :samen_core, :non_pii_repo, SamenCore.TestRepo

# T3.8 Tier-1 custom fields: the repo backing the `tnt_field` catalog + the
# validated-at-write change. Host apps configure their own; the change resolves
# the resource's AshPostgres repo first and falls back to :vault_repo.
config :samen_core, :vault_repo, SamenCore.TestRepo

# Oban in :manual testing mode: `Oban.insert` writes the job row (so the same-tx
# enqueue and its rollback are observable), but queues do NOT auto-execute. The
# auto-revoke test drains the :reveal queue explicitly with
# `Oban.drain_queue/2`. This is what lets the crash test assert "no job row" and
# the auto-revoke test assert "job flips revoked_at".
config :samen_core, Oban, testing: :manual

# T1.8a catalog_parity allow-list: intentional columns that live in the DB but
# are NOT Ash resource attributes (so Samen.Catalog.fields/1 doesn't include them
# and catalog_sync never emitted fld_field rows for them). These are raw DDL
# columns added by migration-level code (the T1.7 erasure fixtures) that the
# erasure system reads directly. They are genuinely non-PII operational columns
# cleared at the migration level — not the T1.8c `non_pii!` review-gate flow.
config :samen_core, :catalog_parity_allow_list, [
  {"pat_patient", "pat_care_note"},
  {"pat_patient", "pat_subject_id"}
]

# ADR-014 RP-D3 suppression fixture (test/support/suppression_fixture.ex) mounts the
# Marketing scope under `sx*` abbrevs to prove the kernel suppression check is portable.
# Its Subscriber declares the standard vault-routed `email` (column `pii_sxs_email`), so
# the column is a real vault promise — but the fixture domain is deliberately NOT in
# `:ash_domains` (kept out of the CI verifier/catalog sweeps), so `vault_declared_parity`
# cannot discover the route. Allow-list the pair: the route IS declared, just not on a
# registered domain. (catalog_parity is satisfied because catalog_sync catalogs it.)
config :samen_core, :vault_declared_parity_allow_list, [
  {"sxs_subscriber", "pii_sxs_email"},
  # WS-A A4 notifications engine fixture (test/support/notification_fixture.ex):
  # Notification.rendered_body is vault-routed (column pii_nen_rendered_body) but the
  # fixture domain is NOT in :ash_domains, so vault_declared_parity cannot discover
  # the route. The route IS declared — allow-list the pair (same posture as sx*).
  {"nen_notification", "pii_nen_rendered_body"},
  # Same fixture, same posture: the Primitives blueprint's Webhook declares the
  # vault-routed signing_secret (column pii_nwh_signing_secret), but the fixture
  # domain is NOT in :ash_domains so vault_declared_parity cannot discover the
  # route. The route IS declared — allow-list the pair.
  {"nwh_webhook", "pii_nwh_signing_secret"},
  # T39 automation fixture (test/support/automation_fixture.ex): the Subject trigger
  # source declares a vault-routed email (column pii_asj_email) so the c2 red-path can
  # prove a condition on it is refused. The fixture domain is NOT in :ash_domains, so
  # vault_declared_parity cannot discover the route — allow-list the pair.
  {"asj_subject", "pii_asj_email"},
  # T34 E3 approvals fixture (test/support/approvals_fixture.ex): the Document Gate-client
  # declares a vault-routed secret (column pii_apd_secret) so the INV-1 no-persisted-inputs
  # proof is non-vacuous. The fixture domain is NOT in :ash_domains — allow-list the pair.
  {"apd_document", "pii_apd_secret"},
  # T41 E4 reminder (test/support/automation_fixture.ex, the SAME AutomationFixture
  # domain T39 mounts): Reminder.note is vault-routed (column pii_arm_note) so the
  # per-plane masking 3-proof is non-vacuous. The fixture domain is NOT in
  # :ash_domains — allow-list the pair.
  {"arm_reminder", "pii_arm_note"},
  # T40 E2 action-library fixture (test/support/automation_fixture.ex, the SAME
  # AutomationFixture domain T39/T41 mount): Target.email is vault-routed
  # (column pii_sat_email) so the webhook snapshot assert's negative control
  # (a vault field named in `include` still never reaches the payload) is
  # non-vacuous. The fixture domain is NOT in :ash_domains — allow-list the pair.
  {"sat_target", "pii_sat_email"},
  # T45 F3 (Docs scope, test/support/docs_fixture.ex): Doc.secure_body /
  # Note.secure_body are vault-routed (columns pii_sdd_secure_body /
  # pii_sdn_secure_body — the "PII-classified routes to vault" path, see
  # Samen.Scopes.Docs.Blueprint) so the INV-1 masking three-proof is
  # non-vacuous. The fixture domain is NOT in :ash_domains — allow-list the pair.
  {"sdd_doc", "pii_sdd_secure_body"},
  {"sdn_note", "pii_sdn_secure_body"},
  # T75 (spec §I2 CRM sequences): a SECOND materialization of the T74 Mailbox
  # scope (test/support/mailbox_fixture.ex) so the sequence reply-detection
  # test can prove Samen.Sequences.MailboxReplyCheck reads REAL MailMessage
  # rows. Connection.address / MailMessage.{subject,body,counterparty_address}
  # are vault-routed (columns pii_scm_address / pii_smm_subject / pii_smm_body /
  # pii_smm_counterparty_address) but this fixture domain is NOT in
  # :ash_domains — allow-list the pairs (same posture as every other fixture
  # above).
  {"scm_connection", "pii_scm_address"},
  {"smm_mail_message", "pii_smm_subject"},
  {"smm_mail_message", "pii_smm_body"},
  {"smm_mail_message", "pii_smm_counterparty_address"}
]

# T34 E3 approve/reject engine (ADR-040 §4). The host-wired seam: the Approval resource +
# its repo. samen_core wires the TestRepo fixture; hosts configure their own (T35).
config :samen_core, Samen.Approvals,
  approval_resource: SamenCore.Support.ApprovalsFixture.Approval,
  repo: SamenCore.TestRepo

# The kind registry (§4.4): `kind => {plane, handler}`. Gate-guarded action kinds route to
# the generic `Samen.Approvals.Gate` handler (re-invokes the action as the requester); the
# Face-1 "test:*" kinds drive the handler-registry proofs (the reveal grant becomes exactly
# this shape of client in T35). Unregistered kinds are refused at write.
config :samen_core, Samen.Approvals.Registry,
  kinds: %{
    (Atom.to_string(SamenCore.Support.ApprovalsFixture.Document) <> ":publish") =>
      {:tenant, Samen.Approvals.Gate},
    (Atom.to_string(SamenCore.Support.ApprovalsFixture.Document) <> ":lock") =>
      {:tenant, Samen.Approvals.Gate},
    "test:note" => {:tenant, SamenCore.Support.ApprovalsFixture.NoteHandler},
    "test:boom" => {:tenant, SamenCore.Support.ApprovalsFixture.BoomHandler},
    # An OPERATOR-plane kind (the reveal "pii_reveal" shape): its rows carry org_id NULL
    # and are structurally invisible to every tenant actor (the cross-org read red test).
    "test:op" => {:operator, SamenCore.Support.ApprovalsFixture.NoteHandler},
    # T35 §4.7: reveal grants are a REAL client of this shape (not just the "test:op"
    # rehearsal above) — samen_core's own reveal test suite runs against the SAME
    # ApprovalsFixture.Approval + TestRepo wiring configured above.
    "pii_reveal" => {:operator, Samen.Reveal.ApprovalHandler},
    # T70 (ADR-043 §6.3 D5): the AI support operator's human-gated send. Operator plane;
    # the ReplyHandler sends via Samen.Delivery.Chokepoint.send/2 ONLY on a distinct-human
    # approve — the AI service principal is never a decider (distinct-party enforced).
    "ai_support_reply" => {:operator, Samen.AI.SupportOperator.ReplyHandler},
    # A4 (ADR-047 §5.3; ADR-043 §6.2 unamended): the agent loop's propose-then-approve
    # seam. TENANT plane — an agent run belongs to the initiating member's org, unlike
    # the operator-plane support draft above. `requested_by` is the AI service principal
    # (reused from §6.3, never a decider); `Samen.AI.Agent.WriteProposal.on_approve/2`
    # executes the governed action with the DECIDING human's actor, inside the decision
    # transaction. An unregistered kind here would make every write proposal refuse
    # `:approval_unavailable` — fail-honest, never an ungated write.
    "ai_agent_write" => {:tenant, Samen.AI.Agent.WriteProposal}
  }

# T2.6 OTel test config: use the pid exporter so tests receive spans as messages
# and can assert on attributes inline. The simple processor sends spans
# synchronously (no buffer) so spans are delivered before the test assertion.
config :opentelemetry,
  span_processor: :simple,
  traces_exporter: {:otel_exporter_pid, self()}

# T82 fix round (fail-honest MED): Samen.Fleet.Registry.cockpit_identity/1 now
# refuses (fail-honest) unless a host EXPLICITLY configures
# :fleet_local_credential. This test suite opts into the reference (non-durable
# in-process) implementation explicitly — the same way Samen.Delivery.FakeProvider
# is explicitly wired rather than silently defaulted to.
config :samen_core, :fleet_local_credential, Samen.Fleet.LocalCredential.Agent
