# Changelog

All notable changes to Samen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); Samen aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from 1.0 onward.

## [Unreleased]

> **Catch-up, 2026-11-13.** This file had not been touched since 2026-09-21 (`72717d25`); the entries below,
> through "Generators, docs and agent experience", are reconstructed from `git log 72717d25..HEAD` and grouped by theme.
> There is no version or tag for them: nothing here has been released, and no number is invented. The detailed
> older entries follow unchanged under "Added" and onward.

### Kernel honest reads (samen_core)

- **Swallow ratchet over `samen_core/lib`.** The pure scanner moves to `Samen.Lint.Swallow` (samen_core); `Samen.Web.Reads.SwallowLint`
  is now the web-layer configuration over it and `Samen.Lint.KernelSwallow` the kernel's, each with its own shrink-only baselines.
  `@reviewed` entries are pinned to a clause count (a clause added to a reviewed function fails), and a second class detects the
  non-rescue swallow (`{:error, _} -> []/nil/0/false/:ok` in a function that calls an Ash/Ecto/Repo read or write). New CI step
  `kernel_swallow_lint`; sabotages 666 and 682 re-anchored onto the shared scanner, 693-695 added.
- **`Samen.Observability.Failure`**: the kernel's value-free failure report (name, org, exception module names); `Guard.report/3` delegates to it.
- **Fail-open sites fixed** (each has a red test, a positive control and a sabotage, 696-706): a failed `aud_chain` existence probe no longer
  skips the chain entry and reports success (`AuditChain.Writer.write/2` now returns `{:error, :audit_chain_unavailable}`); operator
  `suspend/1` and `clear/2` are atomic with their audit entry and a failed lookup is `{:error, :unavailable}`, not "nothing to clear"
  (this also fixes a non-UUID operator id making the audit write raise silently); `Vault.scan_pitr_key_absent/2` fails closed when its
  column probe fails; the `oban_jobs` and `log_telemetry` oracle tiers report a violation, not a clean scan, when their probe fails;
  `SearchIndexGuard`, `PiiReads.Registry` and `Erasure.Completeness` raise on a module whose PII declarations cannot be introspected instead
  of treating it as "declares no PII"; agent proposal expiry withdraws the approval even when the sealed transcript is unreadable (and
  fails the expiry when it cannot); `Samen.Marketing.Consent.state_result/3` tells an unreadable ledger from "no consent on file" and the
  campaign send gate refuses on it.
- Closed-but-silent security sites (AI egress chokepoint, agent approver/breaker/hooks, fleet resolution/authz, identity, operator plane,
  break-glass anchoring) keep their closed answers and now report by name.

### Kernel review fixes (samen_core, samen_web, demo, driftwood, pawchart)

- **Auto-suspend no longer depends on the audit.** `Suspension.suspend/1` commits the suspension first; a failed audit write is
  reported and parked on the break-glass local chain for `Reconciliation` (which now anchors `operator_suspended` entries as
  `operator_suspension` events). `{:ok, row}` carries `row.audit` (`:written | :pending | :lost`; a virtual field, no migration).
  `Budget.record_and_check/1` matches the result explicitly and `BreakGlass.reveal/1` refuses with `{:error, :suspension_failed}` when the
  suspension cannot be written (it used to raise `MatchError` after the ledger row committed). `clear/2` stays atomic. Sabotages 707-709.
- **`AuditChain.Writer.write/2` is atomic** (probe first, insert + chain append in one transaction outside a caller's transaction) and
  the callers that grant or open something propagate its error: impersonation `open/1`, reveal request and grant, approval
  request/decide/cancel; revoke, expiry and archival report instead of dropping it. `FaultRepo` runs `Ecto.Multi`. Sabotages 710-714.
- `Vault.scan_pitr_key_absent/2` and `scan_no_plaintext/2` no longer read a KMS outage as proof of erasure (715). Agent proposals past
  their `deadline_at` cannot be approved into execution whether or not the expiry job ran, `expire_parked/1` returns
  `{:error, :expiry_incomplete}` instead of raising (716-717). `tool_actor_identity` names a tool whose schema cannot be read (718).
  Erasure completeness: one RED test per un-rescued introspection function, sabotage 704 split into 704/719/720. The send gate's unreadable-ledger arm is
  tested (721). A pid on another node is unknown agent provenance and counts as at the depth ceiling (722). The telemetry handler
  lister override exists only in a test build. A failed `:withdrawn` consent row aborts the unsubscribe (723). `reveal_events_for_org/2`,
  `pending_for_org/2` and `Replay.Player.list/2` raise on a failed read; the driftwood and pawchart analytics `register_all/1` return the
  registration error (724-725). `Consent.state/3` is `@deprecated` (use `state_result/3`).
- **Swallow lint widened** (see cookbook Recipe 11): typed literal-returning rescues, "mentioned" rescue variables, `{:ok, lit}` / bare-atom /
  `MapSet.new()` / `_ ->` error arms, transitive I/O, `defmacro` and module-body nodes; reviewed entries pinned by `{count, hash}`; a hard
  per-root ceiling on every baseline. Both baselines were regenerated from the tree. Sabotages 726-731.

### Tenant indexes (ARCH-4)

- **Every org-scoped keyset page is now an index scan.** The tenant tables had no index led by `org_id` (27 of 99
  `org_id` tables in driftwood, 17 of 82 in pawchart, 14 of 74 in demo), so `WHERE org_id = $1 ORDER BY <sort>, id LIMIT n`
  was a sequential scan. `Samen.Indexing` defines the contract, `(org_id, <keyset_sort>, id)`; a resource declares the sort
  with `use Samen.Resource, keyset_sort: :name` (the scope blueprints do it for the resources that have a list view).
- **`mix samen.verify.indexes`** (new; reads the live catalog, fails on anything it cannot inspect, no exemptions) runs as a
  step per app in `ci/steps.conf` and as step 13b of a generated app's `ci.sh`. **`mix samen.gen.indexes`** writes the retrofit
  migration. `Samen.Migration` gains `create_org_keyset_indexes/2` and `create_jsonb_path_index/4` (plus their `drop_` pairs).
- `activities_for_person` / `activities_for_company` filter `get_path(custom, ["crm_refs", …])`; two partial expression
  indexes on the exact expression Ash emits now let Postgres `BitmapOr` it with the `(subject_key, subject_id)` index.
- Fixed on the way: `Samen.AI.Agent.FoldSource` had a table in driftwood but no repo wiring (it defaulted to `SamenCore.TestRepo`);
  `config :samen_core, :samen_ai_agent_fold_source_repo, Driftwood.Repo` added. A host that runs the agent loop needs the same line.
- Tests: `Samen.IndexingTest`, `Samen.Web.TenantIndexPlanTest` (EXPLAIN of the real page query, with a drop-the-index control),
  `Samen.Web.CrmRefsIndexPlanTest`, `Samen.Web.KeysetSortParityTest`. Recorded in ADR-016 §9. Sabotages 732-735.

### Host action required (existing hosts and generated apps)

A generated app is a copy, so these do **not** reach an app generated before the change. Re-generate into a scratch
directory and diff, or apply by hand:

1. **Copy new migrations** (fixed timestamps; each file is the reference in `driftwood/priv/repo/migrations/` or the
   `samen_core/priv/templates/m_*.eex` template), then re-dump `schema.dict.json` with `mix samen.catalog.dump`:
   `20260925100000` rollup `subject_id` becomes text (host-named, e.g. driftwood's `…_driver_load_rollup_subject_id_text.exs`) ·
   `20260925110000` usage-event ledger · `20260926100000` usage tally `reported_quantity` ·
   `20261005100000` entitlement usage limit · `20261006100000` agent cached-input bucket (hosts running the agent loop) ·
   `20261009100000` `samen_replay` (also register `Samen.Replay.Domain` in **both** `:ash_domains` lists) ·
   `20261114100000` the tenant keyset indexes (**ARCH-4** — run `mix samen.gen.indexes` in the host; it writes a
   `CREATE INDEX CONCURRENTLY` migration over every org-scoped resource, safe on populated tables, no write lock; copy the
   `driftwood/priv/repo/migrations/` file as the reference) · `20261114110000` the Work `Task` `crm_refs` expression indexes
   (hosts that mount the Work scope: copy the reference migration, same `CONCURRENTLY` form). Then add
   `mix samen.verify.indexes` to the host gate; a host with large tables should run the two migrations in a quiet
   window or by hand (`mix ecto.migrate --to 20261114100000`) — each index builds without blocking writes but reads the whole table once.
2. **Mount `plug Samen.Web.SecureHeaders`** in the browser pipeline (security headers + a conservative CSP,
   `frame-ancestors 'self'`), and make the session cookie `Secure` in prod: `secure: Application.compile_env(:app,
   :secure_session_cookie, false)` in the endpoint's `@session_options` plus `config :app, secure_session_cookie: true`
   in `config/prod.exs` (see `samen_core/priv/templates/{endpoint_ex,config_prod_exs_web,router_ex}.eex`).
3. **`layout: {Samen.Web.Layouts, :app}` on host-authored `live_session`s.** The framework's route macros now pass it so the
   flash group and connection banner render once from the layout; a host `live_session` without it loses them.
4. **`Samen.Automation.Health.kill` and `rearm` take an `org_id` as their second argument** (`kill(operator, org_id, workflow_id, opts)`): the
   old arity could act on another tenant's workflow. Update direct callers.
5. **AI provider contract (additive).** `%MaskedPayload{}` gains `:system` and `:turns`, `Provider` gains the optional
   `native_tools?/0`, and `Samen.AI.complete/4` accepts `:model`. An adapter that ignores roles behaves as before; one that
   wants native tool use must map `:system`/`:turns` (see `samen_anthropic`). The Anthropic adapter's default model is now
   `claude-opus-5-5` and `max_tokens` 16 000.
6. **Dependency floors.** Ash 3.37.2, AshPostgres 2.15.2, AshOban 0.10.2 (exact pins, moved together with all lock files),
   Bandit `~> 1.14`, and Elixir `>= 1.20.4` / OTP 29.1.1 (every `mix.exs` now says so).
7. **Oban hosts that do not call `Samen.Jobs.install_defaults/1`** must add `{Samen.Jobs.BootRun, workers:
   Samen.Jobs.default_boot_workers()}` so the `aud_event` partition rolls forward at boot (a fresh deploy could not
   write audit events from its first request otherwise). Hosts using `install_defaults/1` get it automatically.
8. **Seed tasks** should boot through `Samen.SeedBoot.start!/2` instead of `@requirements ["app.start"]`, or
   `mix <app>.seed` dies with `:eaddrinuse` while the dev server runs.

### Reads that lie (WP6 phase 1)

- **A failed read no longer renders as an empty one.** `Samen.Web.Reads.Guard` is the single convention: a read returns
  `{:ok, v} | {:error, :unavailable | :forbidden}`; a failure is logged once with the read name and org id (never row
  data, PII or the exception message) and emits `[:samen, :web, :read, :error]`. `%Samen.Web.Page{}` gains `error`;
  `ListLive` keeps the previous page, filter text and selection on a failed re-read and exposes `@list_error` plus a
  `"list_retry"` event (audit F07). CRM (contacts, contact/company detail, companies, gallery, pipeline, calendar,
  dashboard incl. the un-rescued `safe_dashboard` crash F05, sequences, mailbox), Search (F22) and Support (tickets,
  ticket detail F08) show the kit `error_state` with a retry instead of "No contacts yet", "Contact not found",
  "No pipeline stages yet", "No matches" or "No conversation thread yet" + Start conversation; a genuinely missing
  record keeps its 404. Legacy read names keep their return shapes. `command_palette` gains `error`/`retry_event`.
  A swallow ratchet (`Samen.Web.Reads.SwallowLint`) fails CI on any new catch-all `rescue _ -> []`.
  **Host action:** none required. A host view that `use`s `Samen.Web.ListLive` should pass
  `error={@list_error} retry_event="list_retry"` to its `list_view` (without it a failed re-read keeps the old page
  silently; the first read shows the empty state as before). Recipe: `docs/guides/cookbook.md` Recipe 11.

### Reads that lie, phase 2 (WP6)

- **`ListLive` shows a failed page's error by default.** A failed read flags the kept page `error: :unavailable` and
  `list_view` renders the kit error state (retry = `"list_retry"`) from it, so an unwired screen (the Marketing leads lens
  kept the old page and showed an empty state on a failed first read) is honest without any per-screen wiring. An explicit
  `error=` still wins; happy-path markup is unchanged.
- **The rest of the tenant plane reports a failed read.** Billing (overview, invoices, plans, usage, dunning, settings),
  Marketing (campaigns, campaign detail, segments, leads), Work (tasks, task detail, projects, timeline, tree), Files,
  Chat (inbox, room), Notifications (inbox, preferences), Settings (profile, API keys, invitations, security, reveal
  approvals, replays), Flags, the Automation builder, the AI screens (agent runs and detail, CRM preview, support drafts),
  the Support KB and the public help-center portal (which used to 500 on a failed read), Tags, ObjectRef cards (a new
  `{:error, :unavailable}` reason and a "couldn't load this object" chip), Onboarding (a failed org read no longer paints
  "You're all set") and the tenant activation funnel show the kit error state, a per-section error or an error tile instead
  of "No … yet", "… not found", `$0.00`, "No invitations yet." or "No impersonation sessions recorded."; a genuinely empty
  result and a genuinely missing record keep their copy.
- **A failed write tells the user.** `Guard.write/3` passes a write's own tagged return through and turns an exception, an
  exit **or a returned `{:error, %Ash.Error.Unknown{} | %Ash.Error.Framework{}}`** (how a non-bang Ash write reports a
  data-layer outage) into `{:error, :unavailable}`, logged by name and cause as a **write** failure
  (`write failed write=<name>`, telemetry `[:samen, :web, :write, :error]` with `write` and `cause`; reads keep
  `[:samen, :web, :read, :error]`). A returned `Invalid` / `Forbidden` is a real refusal and passes through. Marking a
  notification read, saving a notification preference, revoking an API key or an invitation, minting a key, inviting,
  saving a profile or a flag change, cancelling an agent run and posting a chat message used to discard the result or
  answer "refused"/"not found" for any failure; they now say what happened with fixed, value-free copy, and an outage no
  longer prints denial copy ("Revoke refused (admin role required…)"). Copy that printed an exception or `inspect/1` output
  (flag/automation friendly errors on a raised write, `support_draft`, the campaign send pill, the file-bytes HTTP 500 body,
  the upload form) no longer does.
- **Review follow-ups.** The onboarding wizard's `verified?/2` fails **closed** on an armed host (it returned `true` for an
  unresolvable principal, bypassing the invite capability gate; sabotage 669). The wizard invite step and billing settings
  look the caller's role up through `current_membership_result`: an outage is an error state ("couldn't send — nothing was
  sent", "couldn't check your role"), still fail-closed, never "No membership in context" / "Only an admin can…". "You're all
  set" is derived from the one org read. Account health reports honest absence when a single MRR, active-subscription or
  ticket figure failed (it printed a real-looking `$0` / `0`; sabotages 87 retargeted and 670). Whether the AI draft domain
  or the impersonation-sessions table is **adopted** is decided structurally by the new `Samen.Web.Reads.Adoption`
  (repo started? configured? table present?) instead of by matching exception text: a down repo or an unmigrated table on an
  adopting host is an error, a host that never adopted the feature keeps the documented honest empty (logged once). A
  malformed notification or object-ref id is "not found", not an error log; a flag write denial shows denial copy; a failed
  chat post says why (lapsed gate, participants outage, non-participant, denial, write outage); board totals are an em dash
  when a group count failed.
- **samen_core (additive):** `Samen.Reveal.Grants.pending_for_org_result/2` and `Samen.Replay.Player.list_result/2`
  (the legacy functions are unchanged). **Host action:** none required. A host `live_session` that overrides the
  `list_view` of a `ListLive` view needs no change; a host that calls `Billing.Reads`/`Marketing.Reads`/… read helpers
  keeps every legacy return shape (new `*_result` siblings are additive). The swallow ratchet baseline shrank from 226 to 107
  clauses; the reviewed helpers carry their reason in `Samen.Web.Reads.SwallowLint`.
- **Honest reads, phase 3 review fixes.** Apps made by `mix samen.gen.app` mount `/operator/revenue` and `/operator/analytics` but
  nothing creates `mrr_revenue_rollup` / `paf_product_event_rollup`: a returned query error on a table that is not there
  (`Samen.Web.Reads.Adoption.probe/3`, structural) is now the honest empty, logged once as "feature not adopted", while a renamed
  column on an existing table is still the error pane. A fleet cockpit with no `fleet_namespace` (or one naming a domain with no
  fleet resources) shows the configuration copy, not an outage. **Webhook DLQ replay is atomic:** `Samen.Webhook.Event.replay/3`
  resets the envelope and inserts its `IngestWorker` job in one `Ecto.Multi` transaction (Oban's `oban_jobs` is on the host repo in
  every in-tree host: `config :samen_core, Oban, repo: …`); a failed enqueue rolls the reset back and the envelope stays "dead" and
  replayable. A host whose Oban repo differs from the envelope repo gets `{:error, :queue_repo_mismatch}` and nothing changes.
  An unresolvable `otp_app` can no longer disarm anything: `Samen.Web.Operator.otp_app/1` no longer rescues a raising repo config
  (the request crashes: fail closed) and `CurrentOrg.param_trust_disarmed?/1` / `Impersonation.auth_disarmed?/1` treat a nil
  otp_app as ARMED. The impersonation gate casts the `org_id` first (malformed: `:denied`, no log) and a raising lookup returns
  the new `:unavailable`, which every framework drill-in renders as a retryable error instead of the open-session-with-reason
  form; `Guard` logs only a canonical-UUID org id (else `invalid`). A forbidden read on account/ticket detail, platform billing and
  the account tiles shows denial copy, not the outage pane; the org switcher reads the Org rows alone; deliverability tells a
  failed recipient lookup ("couldn't load recipient") from an unknown one; a CSV import stops on a data-layer outage and reports
  how many rows were imported (`Csv.Report.stopped`); the aggregate screen tells a wired-but-empty loader from an unwired one; a
  raising metrics reporter or host nav resolver is reported by name. **Host action:** a host with its OWN caller of
  `Samen.Web.Operator.Impersonation.gate/3` or `gate_socket/3` (driftwood, pawchart and the framework drill-ins are updated) must
  handle the new `:unavailable` value: render a retryable error, never the open-session form. A host that relied on a mount with no
  resolvable `otp_app` being "disarmed" must set the `:otp_app` label.
- **Honest reads, phase 3 (operator plane + framework gates).** The operator console no longer renders an outage as an empty
  book, a zero or a healthy default. Accounts, desk and platform billing show "couldn't load" per header tile (each count is
  its own read, so one failed queue count is one tile) and the kit error state with a retry for the list/detail; a failed
  ticket or account detail is no longer "not found" (a malformed id still is, without an error log). Revenue (tiles +
  waterfall, cohort grid, plan table), analytics (funnel, retention), deliverability (events, suppressions — a failed
  suppressions read makes the per-event "suppressed?" flag *unknown*), the activity feed (four sub-queries, each named when it
  failed), the aggregate loader and the fleet cockpit fail one pane at a time. A fleet registry outage is an error state, not
  "Fleet not configured" / "No products registered yet" / "Nothing needs attention", and a malformed `activity_counts` entry
  from one product no longer blanks every product's merged counts. Webhook DLQ: a failed read is not "No webhook envelopes",
  and replay/resolve now say when they were refused or failed (they were silently discarded). Desk delete, ticket reply and
  the AI draft button use outage copy for an outage; the draft and analytics-ask paths no longer print `inspect(reason)`, and
  "not adopted / not configured" is decided structurally. Gates keep failing **closed** and now say so in the log by name
  (operator authority, impersonation gate, current-org membership seams, TOTP credential lookup). CSV import row messages
  are value-free. New additive siblings: `Operator.Reads.{accounts,account_metrics,platform_billing,desk,ticket_detail,account_detail}_result`,
  `desk_metrics_status`, `AnalyticsReads.analytics_status`, `RevenueReads.revenue_status`; `DeliverabilityReads.deliverability/4`
  and `ActivityReads.activity/3` return an extra `:failed` key. **Host action:** none. The swallow ratchet baseline fell from
  107 to 33 clauses (the remaining rows are driftwood/pawchart, phase 4). Sabotages 671-673 (plus 07 and 236 re-anchored).
- **Honest reads, phase 4 (the vertical host apps; the swallow baseline is now empty).** Driftwood and PawChart no longer render
  an outage as an empty list or "not found". `Driftwood.Reads` and `PawChartWeb.ClinicReads` gain tagged `*_result` siblings
  (rosters, load board, settlements, `get_driver/settlement/load/owner`, `pets_for_owner`) over `Guard.run`, with the id cast
  first (a malformed id is not-found, no error log); the legacy functions keep their shapes. The broker console (dashboard
  rollup, loads, drivers, settlements), the clinic surface (patients, pets, patient detail) and both operator impersonation
  consoles render the kit error state with a retry, one pane at a time, and never "No loads yet" / "No patients yet." with its
  create CTA for a read that did not happen; a failed owner list also stops the pet form opening (it would save an ownerless
  pet) and shows the pet's owner as unavailable, not "—". Writes tell the user: a load/driver/settlement/patient/pet save,
  delete or reveal request that fails is outage copy (`Guard.write`), never "a load reference is required" / "a first and
  last name are required" / "reveal denied"; a form submit whose changeset carries only an `Ash.Error.Unknown` is the same
  outage. Gates fail closed and say so: a reveal whose grant lookup raises is "couldn't check the reveal grant" (nothing
  revealed), a failed reveal-window lookup shows "unknown" (and reloads once, so a revealed value cannot linger) instead of
  silently hiding the open-window banner, the landing controller answers 503 instead of sending a tenant to the operator
  console when the session read OR the User/Membership read fails (`Samen.Auth.OrgActor.authorized_org_ids_result/2` and
  `resolve_result/3` return `{:error, :unavailable}`; the legacy functions keep their shape, still fail closed, and now log the
  failure by name and exception module), the "no org / run the seed command" card renders the error state when the org
  directory read FAILED rather than was empty (`CurrentOrg.list_orgs_result/1`), a failed org-name lookup shows the id and is reported, and a failed API-key /
  MCP-key lookup is reported by name while still setting no actor. `Driftwood.Directory` and `PawChart.Auth` now let a failing
  read raise: the framework (`CurrentOrg.list_orgs/1`, `authorized_orgs/2`) already catches it, denies and reports it by name.
  **Bugs fixed along the way:** the broker "Edit load" button crashed (it read a `__lane__` the raw row never had);
  `ClinicReads.update_owner/3` treated a failed read of the stored emails/phones as "none stored" and would have overwritten
  them; `PawChart.OperatorSeeds` / `Driftwood.OperatorSeeds` probes answered `true`/`false` on a failed read (skipping or
  repeating a step and still reporting success), the operator-org create fell back to a fresh-id create that the next probe
  could not find (a duplicate org per re-run), and a half-seeded operator org (accounts missing, desk agent gone) reported
  success. A failed seed probe or step is now a failed seed (non-zero exit), and the operator seed units are atomic: the Driftwood
  fresh path and each account it adds on a re-run are one transaction each (the account `Org` row is the "seeded" marker, so it commits
  only with the admin, billing and tickets it vouches for), the leads converge on a re-run, and the PawChart operator seed is one
  transaction (an interrupted run was a permanent half-seed that reported `:ok`); a seed interrupted BEFORE this change still needs a
  database reset (the loud "interrupted" error stays). `mix driftwood.seed` stays re-runnable (verified twice against the dev database);
  `mix pawchart.seed` does not call `PawChart.OperatorSeeds` (it seeds the tenant only), which was exercised directly. Also: a reveal-window outage is re-probed every 20 s instead of logging once a second per open console, and a reveal is refused while the
  windows are unknown; a suspension-table outage on a reveal is outage copy (still denied), not "no active second-party grant"
  (`Suspension.status/2`); every framework form submit (20 of them) and the broker console's go through `Guard.submit_form/4`, so an
  outage is "couldn't save — nothing was saved", a denial is denial copy and validation errors are unchanged; `Guard.pane/2`,
  `error_body/1`, `retry_event/2`, `write_copy/2`, `cast_id/1`, `first_or_not_found/1` and the `<.read_error>` component replace the
  per-vertical copies. **Host action:** none. The swallow ratchet baseline fell from 33 to 0 (the map and
  the shrink-only ratchet stay; nothing may be added back). Sabotages 678-681 (151, 172, 181, 182 regenerated onto the converted
  reads; 666 names the non-vacuity test, since the baseline-equality test cannot flip on an empty baseline) and 682-692 (the live ratchet's
  positive control; the landing 503, no-org error card, reveal-window backoff and refusal, suspension copy, seed atomicity and the form-submit classification).

### Security and correctness fixes

- The LiveView login oracle is closed; rate-limited users land on a real page. Sessions that are revoked disconnect their
  LiveView sockets; a failed revoke is never reported as revoked. Webhook raw-body reading honours the `read_body`
  contract (413, not 500).
- Audit: chain appends are transactional with a per-org advisory lock; `aud_event` partitions roll forward by calendar
  month and at boot.
- Cross-tenant workflow kill/rearm in operator automation health fixed (see host action 4). A feature flag resolves from its
  owner org's rows only. Marketing sends cover the whole segment, are paged and idempotent per (campaign, subscriber);
  CRM sequence enrollment with a blank or unknown contact id is an error.
- Fleet ingress: an unconfigured `/fleet/health` answers 503 with a body that says so. TOTP enrolment keeps its pending
  secret across remounts. Chat/support/operator views show the newest 200 messages. Billing overview shows a plan's real price.
- No local machine paths in tracked files (`scripts/no_local_paths`, with its own sabotages).

### AI plane

- **Instructions apart from data** (ADR-043 §5.1a, ADR-047 §5.2a): sealed `:system` and role-structured `:turns`; native
  tool use with `tool_use`/`tool_result` and honest stop reasons (`:truncated`, `:refused`, `:unexpected_stop`,
  `:rate_limited`, `:overloaded`, `:provider_timeout`); explicit transport timeouts and bounded retry; prompt-cache
  breakpoints; per-agent `model:`. An opt-in live agent trajectory eval (`SAMEN_AI_LIVE`) joins the keyless suite.
- Context compaction (ADR-048) fixes: the failed attempt and the Level 2 summarizer are billed what they spent; cached input
  is its own token bucket end to end (#74).

### Observability, replay and usage metering

- **ADR-052:** the observability plane is lit (LiveView/request wide events, reveal and job spans, OTLP mapping, `:logger` tier
  of `no_plaintext_pii`), and a masked **session replay** ships (capture kernel, default-deny sanitizer, player on both
  planes, `replay_schema` verifier, runbook). Driftwood captures in dev only.
- **ADR-051:** usage-metering capture — an insert-only ledger behind `Samen.Billing.Meter`, `Usage` as a tally derived from it,
  a mirrored per-period limit (`within_limit?/4` fails closed), and a tenant usage panel.

### Ash Signals and dependencies

- Ash 3.34.4 → 3.37.2 (clears 31 advisories), AshPostgres 2.15.2, AshOban 0.10.2; `mix samen.verify.signals_no_pii` (no PII in a
  signal); archive/restore cascades of the CMS, Support, Chat and Work scopes are now Signals listeners (#96).

### CI, tooling and the proof corpus

- **ADR-053:** one driver (`scripts/ci quick|pr|full`), budgeted and resumable, content-cached, mirrored in GitHub Actions;
  `scripts/counts`, `scripts/docs_check`, `sabotage new|reanchor`, N-lane sabotage replay, concurrent gen probes on a private
  abbrev registry, a compiled-dependency cache. The sabotage corpus grew from 356 to the generated count in CLAUDE.md.
- Toolchain pinned (`.tool-versions`: Elixir 1.20.4 / OTP 29.1.1) and enforced by the `toolchain` step; Dialyzer in the default
  gate over all product projects; one sanctioned shared-sandbox helper, `Samen.TestSandbox.shared!/1`.
- Flakes fixed rather than retried: pinned clocks, tests wait for events not durations, sandbox mode is never left `:auto` (#103).

### UI kit, data map and landing page

- Kit: loading/error/empty states, drawer accessibility, flash/connection banner from the LiveView layout, files links that carry
  `?org=`, a sideways-scroll root cause fixed. The operator plane gains a generated **data map** (ERD + architecture, #97).
  The landing page was rebuilt as a feature-by-feature story with real product screens.

### Generators, docs and agent experience

- Generators and `mix samen.abbrev.reserve` refuse unknown or malformed flags before any side effect. Abbrev errors name the
  sanctioned `mix samen.abbrev.reserve` command and the registry file actually read.
- Generated apps ship `AGENTS.md` (the gate, the failure index, the hands-off rules). `mix <app>.seed` no longer starts the
  HTTP listener. Every `mix.exs` and generator template declares `elixir: ">= 1.20.4"`, checked by the `toolchain` step.
- Docs: the glossary, a docs index that separates using Samen from project history, an ADR status column, front-door counts
  generated by `scripts/counts --docs`, getting-started prerequisites; `docs/next-session-brief.md` moved to `docs/archive/`.

### Added

- **The G-06 double sweep is machinery, not prose** (`scripts/double-sweep.sh`, wired
  UNCONDITIONALLY as `./ci.sh`'s first step): every run sweeps the sabotage corpus twice —
  the branch's NEW patches against a pristine `git archive` of `origin/main` (each must
  FAIL there, or it anchors on nothing the branch added) and the WHOLE corpus against the
  tree about to ship (proving no edit disarmed an already-shipped sabotage). The new-patch
  set is derived by set difference and each failing set is re-derived by its own sweep, so
  no count is ever inherited. Distinct exit codes name the failure: 3 anchor, 4 disarm,
  5 accounting. `git apply --check` only — ~6s over 324 patches, no compile, no DB — which
  is what makes an always-on gate affordable; the expensive REPLAY stays the opt-in
  `SAMEN_SABOTAGE=1` harness. Before this the rule lived only in session prompts, and nine
  commits disarmed a shipped sabotage anyway. `scripts/double_sweep_test.sh` (also
  unconditional in `ci.sh`) proves the sweep goes red once per failure class against a
  throwaway fixture repo, including a mutation that deletes its own coverage counter.
- **Canonical Work scope — `Project` + the self-referential `Task`** (ADR-041 §3, F1): a new
  `Samen.Scopes.Work` blueprint ships one canonical Work item (`kind`/`title`/`body`/`status`/
  `priority`/`due_at`/`completed_at`, a generic CRM-agnostic `(subject_key, subject_id)`
  object-ref anchor, `custom`, `owner_id`, and the self-referential `parent_id` Subtask tree
  with cycle refusal), archivable with a subtree cascade. Every vertical inherits Project +
  Task at ≈0 authored LOC; no PII (the scope's catalog PII map is empty).

- **Mutation testing as a gate** (ADR-049): `scripts/mutate.sh` enumerates mutation sites
  **mechanically from the AST** (`scripts/mutation/mutate.exs` — `Code.string_to_quoted/2` with
  `columns: true` plus a literal encoder, never a regex) over four deliberately-chosen operator
  families (`EQ` `==`/`!=`/`===`/`!==`, `REL` `>`/`>=`/`<`/`<=`, `BOOLOP` `and`/`or`/`&&`/`||`,
  `BOOLLIT` `true`/`false`), splices each at its exact line:column, and requires it to be killed by
  that file's **OWNING** test files only — so a kill is attributed by construction, not counted.
  This answers the converse of the question the 328-patch sabotage corpus answers: that corpus
  proves every guarantee the repo *claims* is still guarded, but each sabotage is a claim someone
  thought to make, so it cannot report what it is missing. Where the owning-test column is derived
  from the sabotage `APP:`/`TEST_FILES:` headers, the attribution is already gate-proven. Five
  non-weakenable contracts: **baseline green before scoring** (against a red suite every mutant
  "dies" and the gate reports a confident 100%); **a kill is a NAMED test failure** — a non-zero
  exit with no `N) test` header means the *compiler* refused the mutant, scored `BUILD-REFUSED`
  and never a kill (the owning suites deliberately run **without** `--warnings-as-errors` so a
  warning masquerades as neither); **byte-exact SHA-256 restore** on every exit path including
  SIGINT/SIGTERM; **an unexempt survivor fails the run**; and **the full report before the
  failure** (a mutation run's value is the complete survivor list). Selection mirrors
  `sabotage.sh`'s grammar (`--app`, `--file`, `--family`, `--changed [<ref>]` with the same
  load-bearing untracked-file union, `--list`/`--dry-run`; same-flag-twice is an error; different
  flags intersect; a filtered run's success line is distinct from a full run's) and adds
  `--corpus` (derive the target set from the sabotage corpus — 163 (file, app) rows over 155 distinct lib files / 2,852 mutants, a soak
  not a gate step), `--shard <i>/<n>` (a deterministic partition, proven disjoint **and** total, so
  a soak is schedulable without overlap or gaps), and `--emit-patches <dir>` (write each survivor
  as a sabotage-format patch with `MUST_FAIL` left TODO — the promotion path that turns a
  mechanically-found hole into a permanent hand-named guarantee).
- **The mutation gate's exemption ledger is content-pinned, not line-pinned** (ADR-049 §3):
  `scripts/mutation/ledger.tsv` keys each exemption on the SHA-256 of the **exact source line** it
  excuses, so inserting lines above a justified survivor keeps it valid while **editing that line
  expires it** — `scripts/mutation_lint.sh` then fails the row as STALE. Exactly two classes are
  allowed (`EQUIVALENT` with a specific proof; `ACCEPTED_GAP` with a mandatory `ref=` naming the
  ADR/backlog item that owns the hole) and an exemption whose mutant is now **killed** fails the
  gate as obsolete, so the ledger shrinks by construction as tests land. Exempt and unexempt
  survivors are counted separately, so no report can round a ledgered hole into a clean number.
- **The mutation gate is itself refutable** (ADR-049 §6): `scripts/mutation_selection_test.sh`
  drives the gate's scoring logic against a throwaway probe module with stub runners — 30
  assertions, ~15s, no database, no real mutant applied — with a negative control for each way a
  mutation gate can lie rather than crash: a runner that always passes (every mutant survives, the
  gate must FAIL — a gate that cannot report a survivor reports 100% forever), a failure with no
  test header (must be `BUILD-REFUSED`, zero kills), a RED baseline (must fail **and print no
  score**), a stale ledger hash, an `ACCEPTED_GAP` with no `ref=`, a three-character "reason", an
  exemption whose mutant is now killed, a zero-site watch-list row, a missing owning test file, a
  splice at a column that does not hold the expected token, and `--shard` shards proven both
  disjoint and total. Wired into `ci.sh` as **two unconditional steps** (preflight + self-test,
  ~17s, no DB, nothing mutated) plus one **opt-in** replay tier, `SAMEN_MUTATION=1 ./ci.sh`,
  matching the sabotage harness's posture.

### Fixed

- **An automation run now executes the definition it was TRIGGERED with, not the one the rule
  happens to carry at execution time** (T162, ADR-039 §8.5; `Samen.Automation.Definition`).
  `RunWorker` carried only a `workflow_id` from enqueue to execution and re-read the rule at
  perform time, so a tenant edit landing while a run sat queued — or between Oban retries of
  one job — changed what an already-triggered run did, and a historical `Automation.Run` row
  could only be read against the rule as it looks today. `DispatchWorker` now stamps a
  SNAPSHOT of the definition (`actions`/`conditions`/`resource_key`) plus its content digest
  into the job args as it enqueues; `RunRecord` copies both onto the Run row **from those same
  args** (new `definition` / `definition_digest` columns), so the record and the execution
  cannot disagree, and `digest(run.definition) == run.definition_digest` makes the row
  self-verifying. Retries re-execute the same pin because the pin rides the args. Only the
  DEFINITION is pinned: both kill-switches, the owner and the governed subject re-read stay
  LIVE, so a workflow paused or killed after enqueue still skips — carried as standing
  controls beside the pinning reds, with sabotages `364` (pin recorded but ignored at
  execution) and `365` (enqueue stops stamping). No new PII surface: the snapshot copies three
  columns that are already non-PII by schema via the write-time `NonPiiPredicates` refusal —
  rule structure, never a subject value, so ADR-039 §13's undo-snapshot rejection is untouched.
- **`samen_core/test/test_helper.exs` no longer blows up as a bare `MatchError` when a previous
  run's connections defeat the test-DB drop** (found by ADR-049's gate, which runs `mix test`
  dozens of times back to back and so loses that race regularly): `storage_down` cannot drop the
  database, the following `storage_up` answers `{:error, :already_up}`, and the helper crashed with
  no explanation. The drop is now retried briefly and then fails **loudly** with the reason and the
  fix. `{:error, :already_up}` is deliberately **not** tolerated — the drop is what makes the
  schema match the generated migrations, so accepting an un-dropped database would quietly run the
  suite against a stale schema.

### Changed

- **Six real holes found by the mutation gate's first run are closed with tests** (ADR-049 §7,
  MG-01…MG-06): `Samen.Pii.Classification.pii?/1` — the public "is this type PII" predicate —
  could be **fully inverted** with nothing noticing, because its owning suite tested `classify/1`
  exclusively and `pii?/1` had zero coverage (an inverted `pii?` is a total fail-open);
  `classified?/1`'s unknown-type branch answered on **atom-ness** rather than non-PII-registry
  membership under `and`→`or`, calling every atom "classified"; `Samen.ScopeMaskCase`'s own
  anti-vacuity guard (`names == [] and handles == []`) survived `and`→`or`, which would have
  refused every **one-sided** call — the normal shape of a real mask proof — while every test in
  its suite stayed green; `Samen.Delivery.Chokepoint.resolve_provider/3` returned `{nil, %{}}`
  (which reads downstream as a *resolved* provider — a fail-open onto a nil adapter) because
  `is_atom(nil)` is `true` and the `and not is_nil(...)` half was the entire guard; and
  `suppressed?/2`'s `== true` strict coercion and its documented **fail-closed-on-raise** promise
  ("a broken check must never silently let a send through") both had no test at all. The remaining
  16 survivors are ledgered as individually-referenced `ACCEPTED_GAP`s — highest severity being the
  approval gate's `authorize?: true`, whose loss turns the gate into a policy **bypass** its owning
  suite does not notice — and 1 as a proven `EQUIVALENT`.

- **Tier-1 custom fields gain five new bounded types** (ADR-036 H6): `money`, `url`, `phone`,
  `email`, `address` join `Samen.CustomFields`'s existing `string`/`integer`/`number`/
  `boolean`/`date`/`enum` set, reusing the matching `Samen.Type.*` module's own cast/
  validation logic and bounded constraints (`currencies` allowlist for money; `schemes`/
  `max_length` for url; `max_length` for phone/email; `allowed_countries` for address). A
  non-`pii_declared` custom field of type `email`/`phone`/`address` is refused BY TYPE, not
  merely by value-shape heuristic (closing a gap the heuristic alone can't reach for a
  MAP-valued `address` field) — "a Tier-1 custom field can never be a vault bypass" now holds
  for all eleven types.
- **`mix samen.gen.resource --field-type` — the full rich-type menu** (ADR-036 H7): the
  generator's scaffolded resource's ONE scalar `pii do` vault field can now be declared as
  any of `string | money | percent | score | duration | priority | url | email | phone |
  address` (default `string`, byte-identical to pre-existing output). Every menu entry still
  materializes as a `Samen.Type.VaultField` `vt_*` token column regardless of its declared
  logical type — only the resource's `pii_attribute` declaration and the generated G26 test
  files' sample values vary per entry.
- **`Samen.Web.Csv` gains a Duration cell clause** (ADR-036 D5/H7): the canonical export form
  is ISO-8601 (e.g. `"PT5400S"`), matching the H2 contract table — `Samen.Type.Duration`'s Ash
  value is a bare integer (no wrapper struct), so the cell serializer now consults the
  column's declared Ash type before falling back to the generic value-shape dispatch every
  other cell already used.
- **E7 audit-on-write — the `versioned` blueprint opt-in** (ADR-040 §6, T119): a resource
  declares `use Samen.Resource, versioned: true` (mode `:changes_only`, the default) or
  `versioned: :snapshot` and ash_paper_trail (ADR-037 §5.4 ADOPT) generates a governed
  `<Resource>.Version` recording every create/update/destroy as an attributable, token-only
  diff. The generated version resource gets FULL samen governance (INV-3, §6.2): an
  allocator-owned abbrev injected into its `samen do abbrev end` section at build time (the
  first auto-allocated abbrev on a generated resource; registry stays HANDS-OFF), prefixed
  columns, a mirrored `org_id`, OrgScope policies, catalog registration, and the
  `no_plaintext_pii` roster. INV-1 holds by construction: a vault-routed (🔒) attribute
  versions as its `vt_*` token, NEVER plaintext, for BOTH `:changes_only` and the full-row
  `:snapshot` reconstruction (`store_action_inputs?` is `false` forever; `:full_diff` is
  refused substrate-wide). The four audit tiers stay disjoint (§7.4): a versioned +
  impersonated write produces BOTH a Version row (E7) and a separate §6.6 `impersonation_write`
  governance `aud_event` — never one row serving both (the impersonation-write audit no-ops on
  version resources).

### Fixed

- **`scripts/sabotage.sh` no longer under-reports its own coverage.** The harness is
  fail-fast and iterates in the glob's LEXICOGRAPHIC order (`240-` before `44-`), so an
  abort printed only the patch that died: a `--touching` run that SELECTED 34 and
  EXERCISED 3, and a full run that SELECTED 324 and EXERCISED 34, were both indistinguishable
  from broad coverage. Every exit path now prints `SABOTAGE HARNESS: PROCESSED <n> of <m>
  SELECTED`; an abort additionally NAMES every patch it never exercised and says in words
  that the run is not coverage. Each replayed patch is prefixed `[k/m]`, and `ALL PASSED`
  is now guarded by a `PROCESSED == SELECTED` invariant.

### Removed

- **BREAKING (pre-1.0): the CMS `ContentVersion` resource is retired** (ADR-040 §6.5, T119).
  The bespoke `content_version` ledger (`define_content_version`, the `<abbrev>_content_version`
  table, the admin-gated `:create_version` action) is removed in favor of E7 audit-on-write:
  CMS `Page`/`Post`/`Block` now declare `versioned: :snapshot`, so ash_paper_trail records a
  full-row `<Resource>.Version` snapshot on EVERY tracked write (create/update/publish/
  mark_archived/archive/restore) — fixing the long-standing gap where status transitions
  promised a version but only `set_attribute`'d (nothing ever appended a `ContentVersion` row).
  Content history now reads `Demo.CmsScope.{Page,Post,Block}.Version`; demo's `:create_version`
  smoke/test call sites are rewired to assert the automatic version rows. Zero data drop: the
  ledger held only dev/fixture data (no lifecycle hook ever wrote it, no production host mounts
  the CMS scope), so a clean drop/create produces the paper_trail-backed shape — the historical
  `add_cms_scope` migration no longer creates the table, and a guarded, idempotent
  `DROP TABLE IF EXISTS` + catalog cleanup (T97 move-then-drop convention) sweeps any lingering
  dev DB. The retired `cvr` abbrev stays in the registry (never recycled — permanence). PITR
  is not needed (no data).
- **BREAKING (pre-1.0): the CRM `Activity` resource is removed** (ADR-041 §5, operator ruling
  M5). `Activity` (call/email/meeting/note) was **destructively migrated into the canonical
  Work-scope `Task`** and its table dropped on every host (`act_activity`/`fac_activity`/
  `vce_activity`/`swa_activity` → `<work>_task`). A contract-phase, idempotent, per-host
  `INSERT … ON CONFLICT DO NOTHING` + `DROP TABLE` copies **every** Activity field onto Task
  field-for-field (§5.1) with **zero data drop**: `type→kind`, `subject→title`, body/status/
  due_at/completed_at/custom/id/org_id/timestamps verbatim; the ≤3 CRM foreign keys collapse to
  the primary subject anchor by precedence (`opportunity ▸ person ▸ company`) **and** the full
  non-null ref set is preserved in `custom.crm_refs`. The CRM detail timeline + composer now
  read/write the Work `Task` through the object-ref anchor (OR-matching `custom.crm_refs`), so a
  user sees the identical event stream. Cross-org protection moves from the belongs-to
  `SameOrgFk` to the org-scoped `Samen.Web.ObjectRef.resolve` write boundary — a cross-org
  reference is now **inert** (unresolvable) rather than a `SameOrgFk` validation error.
  Driftwood's `CheckCall` ubiquitous-language alias now re-identifies `Driftwood.Work.Task`.
  PITR is the production control for the contract phase (no `down/0` round-trip).

### Changed

- **BREAKING (pre-1.0): CRM Opportunity + Billing Price money columns.** `Samen.Type.Money`
  (ADR-036 H1, a thin wrapper over `AshMoney.Types.Money` — ADR-037 §5.2 ADOPT) replaces the
  paired `value_cents`/`unit_amount_cents :integer` + `currency :string` convention with ONE
  `money_with_currency` Postgres composite column (`Opportunity.value`, `Price.unit_amount`).
  A destructive, single data-copy migration (no deprecation window — the integer-cents → composite
  transform is a lossless bijection) ships in every host (`demo`, `driftwood` — both the tenant and
  operator Billing mounts, `pawchart`) and in the `mix samen.gen.app` generator templates. Every
  production reader/writer of the old columns (the kernel MRR source, the raw-SQL revenue rollups,
  the `samen_web`/vertical UI, seeds/test-support) was repointed in the same change (ADR-036 §4.5).
  Money self-classifies non-PII behind a foundry-shipped `Samen.NonPii.TypeClearance` entry
  (ADR-034 gate). `Samen.Web.Csv` gained a Money cell clause (`"USD 12.34"`, ISO-4217).

## [0.1.0] — 2026-07-20

First tagged release — the public snapshot of the Samen foundry.

### Included

- **Kernel (`samen_core`)** — per-subject vault + KMS key hierarchy, crypto-shred with a
  destruction oracle, two-plane PII masking, token-blind cross-tenant aggregates, a
  hash-chained append-only audit log, the self-qualifying catalog, and the verifier gate.
- **Web framework (`samen_web`)** — inherited LiveView surfaces (CRUD + list ergonomics,
  notifications inbox, operator cockpit, global search, files, CSV import/export, self-serve
  settings) with per-plane masking by construction.
- **Generators** — `mix samen.gen.*` emit a running, correct-by-construction product with
  web / API / seed / observability / deploy scaffolds, including a readiness (`/readyz`)
  probe over Postgres, the KMS store, and Oban.
- **Verticals** — `driftwood` (freight) and `pawchart` (vet clinic) prove the substrate.
- Workstreams A / B / D / E shipped and adversarially gated — see
  [`docs/saas-gap-roadmap.md`](docs/saas-gap-roadmap.md).

### Notes

- **AI-authored.** Every commit is `Co-Authored-By: Claude` (see the README authorship note).
- Several adapters ship as documented **fail-honest stubs** (SMTP/ESP, S3, Stripe sync): they
  return `{:error, :not_configured}` or a labeled no-op, never a false success. End-user auth
  is **host-owned** — Samen governs the identity and billing you bring.

[0.1.0]: https://github.com/ckluis/samen/releases/tag/v0.1.0
