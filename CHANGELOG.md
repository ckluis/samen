# Changelog

All notable changes to Samen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); Samen aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from 1.0 onward.

## [Unreleased]

> **Catch-up, 2026-11-13.** This file had not been touched since 2026-09-21 (`72717d25`); the entries below,
> through "Generators, docs and agent experience", are reconstructed from `git log 72717d25..HEAD` and grouped by theme.
> There is no version or tag for them: nothing here has been released, and no number is invented. The detailed
> older entries follow unchanged under "Added" and onward.

### Fixed: the Automation engine's guards, owner role, schedule scan, escalation advance and webhook delivery ids

- **Loop and depth guards see the cascade.** A write made by a workflow's action (create, update, or the undo of a
  create) carries the run's `{depth + 1, chain ++ [workflow id]}` in its changeset context
  (`Samen.Automation.Actions.Support.write_context/1`). The event it captures is dispatched at that depth with the workflow
  in its chain, so a workflow whose action re-triggers it is recorded as a skipped `:loop` run, and a chain deeper than
  `:automation_max_depth` as `:depth_exceeded` (ADR-039 §4.7).
- **A workflow runs with its owner's real role.** The run resolves its owner through the host's membership seam
  (`Samen.AI.Agent.Approver.resolve/2`, config `approver_membership`) and acts with the role that membership holds now, so an
  owner who is a viewer cannot make member-only writes and an admin keeps admin. A workflow whose owner has no active
  membership in its org stops with `owner_unavailable`. Host-visible: check your workflow owners (a person who left the org,
  or was suspended, owns workflows that now stop); a host that runs the engine must wire `approver_membership`, and one that
  has not retries the run and ends it as an internal error instead of running it under an unchecked role (ADR-039 §4.5).
- **A due scheduled workflow is dispatched once.** The schedule advance applies only while `next_fire_at` is the value the
  scan read, so of two scans of one workflow one advances it and enqueues the dispatch and the other gets a stale-record
  error and its job ends cancelled (`:trigger_no_longer_applies`, AshOban's mapping), without a retry. A scan that did not
  read the fire time is refused rather than advanced unguarded. The dispatch `event_id` is derived from the workflow id and that fire time (ADR-039 §4.1).
- **An escalation step is advanced once.** `:advance_step` is guarded in SQL on `current_step`, so two advances of one step
  apply once and notify once; the losing advance ends as a cancelled job too, and one that did not read the step is refused
  (ADR-039 §7.3).
- **Each webhook action of a run has its own `delivery_id`.** The first action keeps the id it always had; the action at
  index `n > 0` appends `:n`. A retry of the run gives each action the same id again.
- **A write nested inside a run's write keeps the run's provenance.** The `{depth + 1, chain}` provenance is set under the
  changeset's `shared` context, the part Ash hands on to nested actions, so a second captured record written from a host
  action's `after_action` is dispatched at the same depth and chain and the loop and depth guards still see the cascade. The
  agent's `assign_record_owner` write carries it too.
- **An agent run acts with its owner's real role.** Each turn re-resolves the run's owner through the same membership seam
  (`Samen.AI.Agent.Approver.resolve/2`) and acts with the role that membership holds now: a viewer's run cannot read or write
  what only a member can, and an admin's run keeps admin. An owner who left the org, was suspended or never belonged stops the
  run with `owner_unavailable`, as does a host whose seam is unwired or failing. Host-visible: a host that runs agents must
  wire `approver_membership`, and check that the people who start agent runs hold an active membership.
- **Sabotages 1612 to 1620** name the tests that prove these.
- **ADR text matches the code.** ADR-040 §4.6 states that approval expiry is enforced at decision time and that a host adds
  its own expiry trigger; ADR-039 §4.2 states that capture queries active workflows in the write's transaction.

### Changed: an API key's scopes are enforced, and a key with no scopes is refused

- **A key acts with the lower of its scopes and its role.** Every resource exposed over JSON:API (it carries
  `AshJsonApi.Resource`) gets a policy added FIRST by `Samen.Transformers.ApiKeyScopePolicy`, so a `bypass` the resource
  declares cannot skip it: `policy Samen.Policy.ApiKeyScopeRefused do forbid_if always() end`. The condition is true only
  for a key request whose scopes do not permit the action, so that request is answered with the API's ordinary 403, and for
  every other request the policy does not apply. It never authorizes: the resource's own policies alone decide whether an
  action is allowed, an action none of them covers stays forbidden, and a key can do what both its scopes and those policies
  allow. A resource with `AshJsonApi.Resource` and no `Ash.Policy.Authorizer` no longer compiles. A signed-in person, a system
  actor and any actor with no `:api_key` are not affected. A host with no JSON:API (pawchart) is unchanged; its MCP endpoint
  builds an actor with no `api_key` map, so scopes are not enforced there.
- **The scope grammar.** A scope key is `"all"`, `"<family>"` or `"<family>.<type>"` (atoms or strings), its value a list of
  `"read"` and `"write"`. The family is the underscored last segment of the resource's domain (`Demo.Crm` is `crm`,
  `Driftwood.Freight` is `freight`), or what the domain's `samen_api_family/0` returns; the type is the resource's JSON:API
  type (`contact`, `driver`). A read action needs `read`; a create, update, destroy or generic action needs `write`, and an
  update or destroy by id reads the row first, so it needs `read` as well. `Samen.Scope.ApiKey.permits?/4` is the predicate.
  An empty scope map authorizes nothing.
- **A key that already holds scopes acts within them.** Before, the scopes of a key were stored and never consulted, so it acted
  on its minter's role alone. The API-keys page used to tick `read` only by default, so a key minted there with that default
  reads and no longer writes until it is re-minted. A write route that reads the row before it writes
  (an update or destroy by id) needs both `read` and `write`.
- **Minting a key with no scopes is refused.** `Samen.Web.Settings.ApiKeys.mint/3` returns `{:error, :no_scopes}` when the
  requested scopes, after the trim to the minter's role (a viewer's `write` is dropped), leave none, and the API-keys page
  says "Choose at least one scope". Scopes may now be a family or `family.type`, not only `all`.
- **The scopes a key is created with are checked.** The `ApiKey` resource's own `:create` refuses an empty scope map and any
  scope key or value outside the grammar (`Samen.Scope.ApiKey.Grammar`: lowercase names, one optional dot, `read` and
  `write`). The resource cannot know a host's router, so `Samen.Web.Settings.ApiKeys.mint/3` also refuses a family or
  `family.type` the app does not expose over JSON:API, returning `{:error, {:invalid_scopes, reason}}` (`known_scopes:`
  overrides the families it derives from the app's domains). A domain whose `samen_api_family/0` returns a name containing a
  dot makes its JSON:API resources fail to compile, because `family.type` is split on the dot.
- **`mix samen.gen.api_key_scopes`** writes the data migration for keys that already exist with empty scopes: an owner,
  admin or member key gets `{"all": ["read", "write"]}`, a viewer key `{"all": ["read"]}` (what their minter's role already
  allowed), in batches of 5,000 rows. A key with scopes, or with no known role, is not touched; the statements only match
  rows that are still empty, so a second run changes nothing and the generator itself skips a table a migration already
  backfills. Committed for demo, driftwood (both key tables), pawchart and samen_web.
- **Upgrading a host.** (1) Run `mix samen.gen.api_key_scopes` in the app and commit the migration; (2) run
  `mix ecto.migrate`, before or with the deploy; (3) re-mint any key that should be narrower or wider than its
  minter's role allows, including a key minted with the page's former default of `read` only that needs to write; (4) a script or test that creates a key with `%{}` scopes now gets an error: give it
  `%{"all" => ["read"]}` or the family it uses (`%{"crm" => ["read"]}`); (5) a resource of your own with
  `extensions: [AshJsonApi.Resource]` needs `authorizers: [Ash.Policy.Authorizer]`.
- Proven by `api_key_scope_enforcement_test.exs` in demo and driftwood (through the real router and key plug, with a fixture
  domain for the write route and a `bypass`), the guards `api_key_scope_guard_test.exs` in demo, driftwood, pawchart and
  samen_core, `scope_api_key_permits_test.exs`, `api_key_scopes_gen_test.exs` (the migration run against a scratch database),
  and sabotages 1584, 1586 to 1592, 1594 to 1601 and 1603 to 1611. ADR-029 records the amendment.

### Fixed: the flag-taking mix tasks refuse an unknown flag

- **A guessed or misspelled flag on a generator or verifier is refused, not dropped.** The generated `AGENTS.md` says every
  generator refuses unknown flags; `samen.gen.indexes`, `samen.gen.reveal_requests`, `samen.gen.api_key_digest_unique` and
  `samen.gen.csat_token_digest_unique` did not, and neither did 18 other tasks: `samen.verify.{fleet_wire, signals_no_pii,
  vault_declared_parity, agent_coverage, catalog_parity, metric_labels, vault_token_binding, tnt_catalog, no_pii_columns,
  aggregate_privacy, indexes, prefixes, no_pan_columns, same_org_fk, ai_prompt_masking, tnt_boundary, api_contract}`,
  `samen.audit.freeform_projection` and `samen.ai.smoke`. They now parse through `Samen.Gen.Args.parse!/3`, which raises
  `Mix.Error` ("mix <task>: unknown flag --x ... Valid switches: ...", a non-zero exit) before the task does anything; a
  positional argument is refused too. Every flag the repo's own CI steps, templates and probes pass is a declared switch. The
  eight tasks that already refused through `OptionParser.parse!/2` (`samen.verify.{migrations, read_scope, pii_classify,
  never_read_current, catalog_meaning, no_plaintext_pii, pii_reads}` and `samen.catalog.dump`) are unchanged. Proven by
  `mix_task_unknown_flags_test.exs` (each family through the task's `run/1`, with a child-process positive control) and
  sabotages 1581 to 1583.

### Fixed: the broker console acts as the signed-in person

- **Driftwood's `/broker` page resolves who acts through `Samen.Web.TenantActor`.** The console built its actor with a fixed
  `:member` role (`BrokerLive.broker_scope/1`), so a signed-in viewer wrote like a member. The page now acts with the role of
  the person's active membership, re-resolved before every event; a viewer's page renders no write control and a crafted
  write event is answered with a flash and writes nothing; a person with no membership gets the denied state, and an open
  form is closed when the role changes. `BrokerLive.dispatch_decision/2`, `create_load/2`, `update_load/3` and
  `delete_load/2` take the acting scope in place of an org id, and `broker_scope/1` is gone. Sabotage 1579 removes the viewer
  refusal and flips the broker role test.

### Fixed: the clinic page acts as the signed-in person

- **PawChart's clinic page resolves who acts through `Samen.Web.TenantActor`.** The page and `PawChartWeb.ClinicReads` used a
  synthetic actor with a fixed `:member` role, so a signed-in viewer wrote like a member. The page now acts with the role of the
  person's active membership, re-resolved before every event; a viewer's page renders no write control and a crafted write
  event is answered with a flash and writes nothing; a person with no membership in the clinic gets the denied state.
  `ClinicReads.create_owner/2`, `update_owner/3`, `create_pet/2` and `update_pet/3` take the acting scope in place of an org
  id, and `ClinicReads.tenant_scope/1` is gone. Sabotage 1578 removes the viewer refusal and flips the clinic role test.

### Fixed: the operator joins read every row

- **Accounts, platform billing and the help desk read their joins to the end.** The tenant-admin, membership, user, customer,
  subscription, plan, price, invoice, ticket, agent and conversation reads behind the Accounts header, the per-account health
  rows, platform MRR and the desk used to stop at their first 200 rows, oldest first, so the numbers were wrong from the 201st
  tenant. `Samen.Web.Operator.Reads` now reads each in keyset pages on `id` until the end (the page bounds a read, not the set)
  and orders the result in memory where order matters. Sabotage 1577 proves the account count, the platform billing
  rows and the desk list past one page.

### Fixed: the contact and company pages render on a host without the Work scope

- **The log-activity composer is built only when the host mounts the Work scope.** The contact and company detail pages wrote a
  logged activity through a Work task form built on every load; on a host with no Work scope that form was built over no
  resource. They now build no composer there, render without it, and answer a composer event with a flash naming the Work scope.
  Sabotage 1576 restores the unconditional build and flips the contact-page test.

### Fixed: the fleet kill switch asks before it publishes

- **`FleetDirectivesLive`'s "Kill switch — all products" carries the confirm interlock and a disabled-while-running state.** The
  button renders `data-confirm` and `phx-disable-with` (and still only for a fleet admin); the handler publishes one directive
  for an admin and none for a read-only role. Sabotage 1575 removes the interlock and flips the render test.

### Fixed: a `data-confirm` control asks before it acts

- **The served client script confirms every control that carries `data-confirm`.** The kit renders the attribute on each
  destructive control (delete, workflow kill, agent stop, approve an AI write), and `app.js` now asks the attribute's text with
  `window.confirm` from a capture-phase `click` and `submit` listener on `document`, so it runs before LiveView's own listeners:
  on refusal the event is stopped (`preventDefault` and `stopImmediatePropagation`) and no `phx-click`, link or form submit
  follows. The listeners are delegated, so elements patched in later are covered, and a form is asked once on submit. Hosts and
  generated apps serve the same file at no authored code. `Samen.Web.ConfirmInterlockTest` runs the file against a DOM stub under
  node and checks that every layout and host endpoint that serves the LiveView client serves `app.js` with it, and
  `Samen.EndpointTemplateServesAppJsTest` checks the generator's endpoint template the same way; sabotages 1573, 1574 and 1580
  prove them.

### Changed: loading sample data is an admin's and runs as the person

- **`SampleData.load/3` takes the acting person's scope.** Loading the sample records is an admin's (it writes org-wide through
  resources whose kernel policy only checks the org): a scope below `:admin` is refused before anything is written, and the
  seed and its audit line run as that person. The Contacts page offers it to an admin only (`:can_admin`), and the first-run
  probe (`FirstRun.first_run?/3`) reads with the acting person's scope. **Upgrade note:** a member no longer loads sample
  data, and host code calling `SampleData.load/2` or `FirstRun.first_run?/2` passes the acting scope as a third argument.
  Sabotage 1419 (which removed the earlier member check on the Contacts page) now removes this admin check and flips the
  same test; sabotage 1569 proves it through the page.

### Changed: no write helper hands an admin role to the operator plane

- **The tenant-admin write helpers answer a read-only scope where the elevation is not theirs.** `Billing.Reads.write_scope/3`,
  `Marketing.Reads.write_scope/3` and `Support.KbReads.write_scope/3` answer `TenantActor.read_only_scope/2` (the plane's actor
  with the lowest role and `read_only: true`) on an operator-plane mount; `Flags.Reads.write_scope/3` elevates only the
  operator workspace's own mount (`Samen.Web.Operator.FlagAdminLive`) and answers the read-only scope on every other mount. A
  tenant page writes with `TenantActor.write_scope/3`. `close_edit`, `dismiss_key` and `dismiss_token` join the read events an
  operator-plane mount of a tenant page may send (they persist nothing).

### Changed: the settings pages and the onboarding wizard act as the signed-in person

- **The API keys, invitations, reveal approvals and security pages and the onboarding wizard resolve their actor** through
  `Samen.Web.TenantActor`: no active membership is the denied state (a failed lookup the unavailable state) and reads
  nothing, an open page re-resolves before every event, and their lists read as that person. The pages
  are readable by every active member; minting and revoking a key, inviting and revoking an invitation, deciding a reveal
  request and every write of the onboarding wizard (including its no-JS form posts) are an admin's, checked by the handler
  against the role resolved for that event and offered to an admin only. The security page reads the person's own account and
  writes nothing.

### Changed: the automation builder acts as the signed-in person; every write is an admin's

- **The automation builder resolves its actor** through `Samen.Web.TenantActor`: the role comes from the person's active
  membership, no active membership is the denied state (a failed lookup the unavailable state) and reads nothing, and an open
  page re-resolves before every event, closing an editor opened under a role the person no longer holds. The workflows are
  readable by every active member; every write (author, edit, pause or resume, run now, add or remove a condition or an action)
  is an admin's, checked by the handler itself, offered to an admin only, and run as the person (`TenantActor.write_scope/3`).

### Changed: the file upload and preview pages act as the signed-in person

- **The file upload page and the file preview page resolve their actor** through `Samen.Web.TenantActor`: the role comes from
  the person's active membership, no active membership is the denied state (a failed lookup the unavailable state) and reads
  nothing, and an open page re-resolves before every event. Listing and previewing files is a read open to every active
  member; uploading is a member's, checked by the handler and offered to a member only. The per-plane masking of the filename
  and the byte gate of the preview are unchanged.

### Changed: the chat inbox and room act as the signed-in person

- **The chat inbox and the chat room resolve their actor** through `Samen.Web.TenantActor`: the role comes from the
  person's active membership, no active membership is the denied state (a failed lookup the unavailable state) and reads
  nothing, and an open page re-resolves before every event and before every realtime delivery, so a person suspended while the
  room is open receives no further message. Reading the inbox and a room is open to every active member; starting a
  conversation and posting a message are a member's, checked by the handler and offered to a member only; flipping the
  org-wide identity disclosure is an admin's and `Chat.set_disclosure_setting_as/3` runs it with `TenantActor.write_scope/3`, so
  the person's own role is what the kernel judges. The operator desk keeps its impersonation gate and masked reads.

### Changed: the feature-flags settings page and the calendar export act as the signed-in person

- **The feature-flags settings page and the `.ics` export resolve their actor** through `Samen.Web.TenantActor`: the role
  comes from the person's active membership, no active membership is the denied state (an export answers 403, a failed lookup
  503), and an open page re-resolves before every event. The flags page is readable by every active member; every flag write
  (enable or disable, ramp, add or remove a rule) is an admin's, checked by the handler itself, offered to an admin only, and
  run as the person (`TenantActor.write_scope/3`). The export is a read open to every active member and records the role it
  ran as.

### Changed: the analytics and search pages act as the signed-in person

- **The own-org analytics page and the ⌘K search page resolve their actor** through `Samen.Web.TenantActor`, as the earlier
  families do: the role comes from the person's active membership; no active membership renders the denied state (a failed
  lookup the unavailable state) and reads nothing; an open page re-resolves before every event, and a navigation (`?org=`)
  reloads. Both are reads open to every active member; the analytics read keeps its own rank gate, which now judges the real
  role and admits an owner (it used to see every signed-in person as a member). The notification inbox unfurls a subject with
  the recipient's own scope. `TenantActor.user_scope/4` is the scope of a user a page already resolved (the inbox,
  preferences, profile).

### Changed: a tenant page on the operator plane is read-only

- **A tenant page on the operator plane is read-only; impersonation is the route for acting in a tenant.** An operator who
  opens a tenant's pages reads them, masked per the plane's masking rules, and offers no write control (`:can_write` and
  `:can_admin` are false). For a page that calls `TenantActor.assign_actor/2`, the refusal is the default:
  `TenantActor.recheck_event/3` halts, on an operator-plane mount, every event that is not a read event (the list's own sort,
  filter, paginate, select and archived toggle, a retry, a tab, a form validation or cancel) and puts the page's own flash on
  the socket. The onboarding wizard's no-JS POSTs are checked by the handler itself: it refuses a person who is not an admin
  before `Onboarding.*` is reached. `TenantActor.write_scope/3` on the operator plane returns the plane's actor with the lowest
  role and `read_only: true`, never an admin elevation. Operator-plane pages proper (`Samen.Web.Operator*`) and the disarmed
  dev posture are unchanged. Proven by `tenant_actor_operator_read_only_test.exs` (plans toggle and delete, invoice, segment
  and campaign delete, a ticket status change and a list restore, each with a tenant admin's positive control) and by
  sabotages 1548 and 1549, the wizard controller's own check by sabotage 1570 and the chat disclosure context by sabotage 1571.

### Fixed: a form built before a demotion or an organisation switch is never submitted with the authority it was built with

- **A navigation on an open page now follows the person acting, as an event does.** `Samen.Web.TenantActor.assign_actor/2`
  used to replace the held scope silently when `handle_params` ran again (a `live_patch`, back/forward, an `?org=` switch), so
  the next event's recheck saw no change and the page's `actor_changed/1` never ran. It now runs when the person acting is
  another id or role, or the organisation changed, exactly as on the event path. **Billing plans:** the edit form was kept
  across loads, so an admin demoted to member (or switched to another organisation where they are a member) could still save
  it with the admin scope it was built with, including into the organisation it was opened in; it is now built again on every
  load from the plan the page reads, with the scope of the person acting, and closed when the plan is not on the page. The
  other converted pages already built their forms again on every load; a test per family (Work, Support) and for the
  two-organisation case pins it. The earlier entry's claim that a demotion takes effect while a page is open held for events
  only until this fix.

- **`TenantActor.write_scope/3` fails closed.** On an armed tenant mount anything that is not a `%Samen.Scope{}` (a `nil`, a
  map) raises `ArgumentError`; it used to be handed to the dev elevation, which on an armed host with no principal answers a
  `:member` scope. It accepts any `%Samen.Scope{}`: that the scope is the page's own acting one is what the guard ratchet
  below checks at the call sites. Only the disarmed dev posture and the operator plane keep the posture's admin elevation, as
  before. (Superseded: the operator plane now answers a read-only scope there; see
  "Changed: a tenant page on the operator plane is read-only" above.)

- **`admin?/1` is false on the operator plane.** It was true there, so the campaign page's send handler, whose page-level
  check is `admin?/1`, accepted a forged send event on an operator socket (the composer was already hidden); the send control
  and that check now refuse there. The disarmed dev posture keeps `admin?/1` open. `member?/1` is left a rank check on
  purpose: the operator's synthetic scope carries `:member`, and an operator's reply is refused by the kernel's
  plaintext-PII `WriteGuard`, which the operator red paths drive the write through to.
- **The guard ratchet sees `write_scope`.** `Samen.Web.TenantActor.Guard.foreign_write_scopes/1` counts a
  `TenantActor.write_scope(` call whose third argument is not the page's own acting scope (a literal `nil`, another scope,
  a capture, `apply`, an `import`); the baseline is empty and `Billing.Reads.restore_admin_scope/2` passes the socket's
  acting scope instead of the list's. The by-name non-vacuity check names the Billing, Marketing and Support pages too.
- **Flake: the abbrev prefix property generated an attribute name the catalog refuses (`:ct26vt_454`).** The generator's domain
  now excludes a name carrying the vault-token sentinel, asking the same `Samen.AI.VtSentinel.in_string?/1` the meaning
  transformer calls; the prefix assertions are unchanged and a deterministic test pins both sides of the generator's boundary.
  A second test compiles a resource whose attribute NAME carries the sentinel and pins that `MeaningDeclarations` refuses it
  with its message (a pin of existing behaviour: it passed before the round).
- **The guard ratchet resolves `alias … TenantActor, as: X`.** `foreign_write_scopes/1` counts `X.write_scope(…)`, a
  `&X.write_scope/3` capture and `apply(X, :write_scope, …)` like the unaliased spellings. **Billing plans:** `toggle_feature`
  no longer builds the edit form itself; it names the plan and lets `load/2` build the form from the current acting scope,
  so a role that changed between the event guard and the handler's own load cannot leave a form with the earlier scope.
- Sabotages 1539 to 1542 (a navigation that does not follow the person acting, the Plans edit form kept for a plan that is not on
  the page, `write_scope/3` falling back on an armed mount, `admin?/1` open on the operator plane) and 1543 to 1547 (the
  driver honouring a test seam without the self-test marker or with a malformed value, a leader that outlives SIGKILL not
  reported, the guard ratchet not resolving `alias … TenantActor, as: X`, `toggle_feature` building the form with the held
  scope). No migration.

### Tooling: the driver waits for a killed process group to be gone

- **After SIGKILL the driver waits until the whole group no longer exists before it returns or exits.** It used to reap
  only the leader (and, in `terminate_all`'s last loop, nothing): a SIGKILLed grandchild is a zombie until launchd reaps
  it, so under load an interrupted driver exited with a group member still visible (the `GROUPKILL` flake). The wait is
  bounded (10 s); past it the driver says so on stderr naming the group and keeps it recorded in `state.json`, so the
  next invocation still refuses to overlap. The leader is reaped on the same bound (a leader that never dies is reported
  and recorded, not waited on forever). The `KILLWAIT` case proves both through test-only seams (docs/ci.md).
- **No test seam reaches a real run silently.** Every `SAMEN_CI_TEST_*` variable is honoured only with the marker
  `scripts/ci_test.sh` sets (`SAMEN_CI_SELFTEST`, stripped from every step); set without it, or with a value that is not
  a finite number of seconds >= 0, the driver exits 2 at startup naming the variable (`SEAMGUARD`). docs/ci.md says
  what to check and remove when a "still running" refusal is a reused process-group id.

### Tooling: a sabotage refused at build time is killed by that refusal

- **A sabotage whose mutation a named compile-time rule refuses is recorded as killed by that refusal, and only when it
  is listed.** `scripts/sabotages/BUILD_REFUSED.tsv` lists the patch, the required substring of the compiler output (the
  rule's own message) and the reason; `scripts/sabotage.sh` reports a listed patch whose build is refused with that
  message as `KILLED (build refused: …)` and counts it as a pass. Refused without the message, or built successfully (a
  stale entry), fails; an unlisted patch whose build is refused fails as before; a bad entry fails the preflight.
  Sabotages 1491 and 1492 (a reveal probe taking a caller-supplied `actor_id`, refused by `Samen.Reveal.ProbeGuard`) are
  back to their original mutation and listed; 1522-1527 prove the ledger rules.

### Fixed: flakes and guards round 5 (review of the flakes round, 2026-11-25; includes the `:host_domains` rename)

- **Upgrade: rename `config :samen_core, :ash_domains, [...]` to `config :samen_core, :host_domains, [...]`.** samen reused
  Ash's own key for the `:samen_core` application as its host-domain registry, so `Ash.Resource.verify` read the host's
  not-yet-compiled domains while samen_core compiled as a dependency and printed `Demo.Crm is not a Spark DSL module` (nine
  warning blocks per host build, and the inclusion check skipped there). Every reader (catalog, MCP, data map,
  no_plaintext_pii, pii_reads, `samen.verify.*`, erasure) now goes through `Samen.HostDomains.registry/0`. Your own
  `config :my_app, ash_domains: [...]` is unchanged, and so is Ash's check on samen_core's own build. For this release the
  old key is still read when `:host_domains` is not configured, with a deprecation warning, so an un-renamed host never
  sees an empty registry (the verifiers that fail on zero resources still do). `mix samen.gen.app` / `samen.gen.scope`
  emit and edit the new key; the five config goldens moved with it. Measured: demo `MIX_ENV=test mix deps.compile samen_core
  --force` went from 9 such warnings to 0.
- **`Samen.OrgIdPinnedGuard.walk/3` (host-visible).** `repos:` is no longer what turns the query watch on: the watched repos
  are derived from the walked resources (read and mutate repo), united with any you pass, and a Postgres-backed resource
  whose repo cannot be resolved fails the walk by name. A query issued by a process the build started (`$callers`, a `Task`)
  counts. An action that takes `org_id` as an argument and sets it in a `before_action` hook (`Marketing`'s `Send`) is no
  longer counted as exercised: the report has `hook_set`, `hook_set_unlisted` and `hook_set_unproven`, and a host lists each
  such action in `hook_set:` with a reason and the named behavioural test that proves a foreign org is refused (the walk
  checks the test is in the file). The three host guards assert both lists are empty. Hosts that pass `repos:` keep working.
- **`Samen.VaultTokenAssert` takes only text (host-visible).** `refute_vault_token/3`, `assert_vault_token/2` and `leaks/2`
  accept a binary or iodata and flunk, naming the input, on `nil` or anything else (they used to `to_string/1` it, so
  `refute_vault_token(nil)` passed). No call site in the five suites passed one. The `phx-` blanking is anchored to an
  `id="phx-..."` attribute.
- **Marketing `Send :create_checked`:** an authorized org-A actor passing `org_id: B` for a subscriber in B is a tested
  refusal that names the pin that refused it (it depended on `before_action` hook order only); a subscriber lookup that
  FAILS is reported (`Samen.Observability.Failure`, `marketing_send_subscriber_lookup`) and refused with its own message
  instead of "subscriber not found". **Freight `ApiKey :create`:** the minter is checked against the org the row is created
  in, not the one the changeset was built with.
- **Vault-token bare guard** now sees assertions that span lines, pipes, captures, `Regex.match?` / `String.match?`, every
  regex delimiter, `String.contains?` with a list and module-attribute patterns; an exemption is a trailing
  `# bare-vt_-ok: <why>` and the exact set is pinned per file. The generated `record_api_test` checks the body with
  `refute_vault_token(boundary: true)`.

### Fixed: authorization and honesty round 5 (evaluation 2026-11-24; tenant roles, authorization and honest reads)

- **Fixed: a signed-in `:viewer` acted as a `:member` on the tenant list surfaces, CSV export, file bytes and the profile
  page.** `Samen.Web.Plane.scope/2` (through `Mount.scope/2`) gave every tenant actor a fixed `role: :member`; since a real
  spine login can pass an armed host, a viewer could create and delete companies and contacts (and, where a policy reserves
  it, anything else a member may) through the generic CRM list screens, and CSV export and file bytes ran as a member. A
  new shared resolver, `Samen.Web.TenantActor.scope/3` (over the same `Settings.Reads.actor_in_org/3` +
  `Samen.Auth.OrgActor` the notification pages use), builds the scope from the person's ACTIVE membership: the role and the
  per-org user id. On an armed host a person with no active membership is refused (the denied card, or 403 on CSV and
  bytes) and a failed lookup is an error state (the unavailable card, or 503). A refused list page takes its list context
  away (`Samen.Web.ListLive.refuse/1`): a later `toggle_archived`, `restore` or any other list event reads nothing and
  writes nothing, including after a suspension or after `?org=` moves to an org the person holds no membership in. Nothing
  ever falls back to a default role: on an armed mount a socket that never ran the tenant gate (no pinned principal) and a
  `{:dev, _}` principal are refused too. The disarmed dev posture and the operator plane are unchanged
  (`TenantActor.system_scope/2` names the fixed `:member` scope where it is really meant). Converted:
  `CRM.ContactsLive`, `CRM.CompaniesLive`, `CRM.ContactLive` (the detail page: edit and delete), `Csv.ImportLive`,
  `Marketing.LeadsLive` (the list scope its restore runs under), `Csv.ExportController`, `Files.BytesController` and
  `Settings.ProfileLive` (CSV and bytes expose the role they acted with as the `:samen_acting_role` conn assign;
  `ProfileLive` refuses a save when nobody is acting instead of rebuilding a scope from a nil role). A session carrying
  both the legacy `samen_current_user` key and the spine token acts as ONE person everywhere: `CurrentOrg.principal_key/2`
  is the single order (the legacy key when the host's `:authorized_orgs` seam grants it an org, the spine credential
  otherwise) and `principal_id/2`, `Settings.Reads.principal_ref/3` and `authorized_orgs/2` all follow it, so CRM, files,
  CSV and profile, Billing elevation, AI agent consent and audit attribution name the same person. **A new framework
  sign-in drops the legacy `samen_current_user` key** (it used to survive `finish_login`, so signing in over another
  person's legacy session kept acting as them); logout clears both keys.
  **Generated `--live` screens** (index, show, form) read the role from the same resolver instead of
  `TenantRole.membership_role/3` (whose fallback for "no membership" was `:member`) and show the same two states. The shared
  pieces the remaining conversions use are `TenantActor.assign_actor/2`, `TenantActor.Components.actor_refused/1` and
  `TenantActor.refuse_events/0,1`. `Samen.Web.TenantActorGuardTest` holds per-file ratchets over the `Mount.scope/2` /
  `Plane.scope/2` calls in samen_web that are not converted yet (every spelling: the `&Mount.scope/2` capture, an `as:`
  alias, an `import`, `apply/3`), over literal tenant actor maps, and over callers of `system_scope`, `admin_scope` and a
  role-less `user_scope` (a literal `nil` role included); its baseline total is pinned, and driftwood and pawchart ratchet
  their own request-path sites. The literal-role detector counts an id-less `%{org_id: o, role: :admin}`, a nested map, a
  `%{actor | role: :admin}` update and `Map.put`/`Map.merge` of a literal role; `except: [scope_kind: 1]` no longer reads as
  excluding `scope`, and an `alias ...,` split over two lines is seen. The hosts' seeds, workers and game days that spell a
  role are listed by file and count.
  **Upgrade notes:** (1) an ARMED host whose signed-in users have no active `Identity.Membership` row in the org they act in
  (a legacy `samen_current_user` host that never created one) now gets the denied state on those screens, and 403 on CSV
  export and file bytes, instead of acting as a member; create the membership rows. (2) A CRM, CSV or files mount now
  needs the `:identity_namespace` label (the host's Identity namespace, as driftwood and pawchart set it): without it the
  membership lookup cannot resolve `<namespace>.User`, so every armed user sees the unavailable state (or 503) and the
  failure is logged on each request. (3) `socket_scope/2` on an armed mount refuses a socket the tenant gate never ran on:
  mount `ContactsLive`, `CompaniesLive` and `ProfileLive` only in a `live_session` carrying
  `{Samen.Web.TenantAuthz, :require_tenant}` (the router macros do). Sabotages 1402 to 1430 and 1436 to 1446.

- **Fixed: the file-bytes and CSV-export routes answered 503 "no mount" on every host.** `samen_files_routes/3` and
  `samen_csv_routes/3` emitted `GET <path>/:id/bytes` and `GET <path>/export/:resource` without
  `assigns: %{samen_mount: mount}` (the ICS route has it) and no host pipeline sets it, so through any real router every
  request was a 503, including the `/files/<id>/bytes` links the files UI renders; the tests that said "via the mounted
  route" set the assign by hand. Both routes now carry the mount and work: a member downloads an active file's bytes and
  exports a CSV, a viewer gets what the policies give a viewer, a person with no active membership gets 403, and a
  quarantined file is not served (tests drive the real router with a real login, in samen_web, driftwood and pawchart). Now that
  they are reachable they are hardened: uploaded bytes are sent with `X-Content-Type-Options: nosniff` and, unless the
  type is a safe inline one (png, jpeg, gif, webp, pdf, plain text), as an attachment under `Content-Security-Policy:
  default-src 'none'; sandbox; frame-ancestors 'none'`, so an uploaded HTML file can neither run as a page on the app's origin
  nor be framed; a CSV export is refused with 413 above `Samen.Web.Csv.max_export_rows/0` rows (`config :samen_web,
  Samen.Web.Csv, max_export_rows: n`, default 100,000) by a scoped count BEFORE any row is read or vault-resolved (an
  org above the limit costs one aggregate, not a full scan; a count that fails refuses too), and an export that fails
  answers with fixed copy rather than the reason term. **Both are audited** (`Samen.Web.AccessAudit`, through
  `Samen.AuditChain.Writer`, the sink the sample-data load and the DSAR export use): a `csv_export` line (actor, org,
  resource, row count, outcome) and a `file_download` line (actor, org, file id, byte size, outcome), refusals
  (403, 413, 422, quarantined) included. Like the DSAR export, a delivery is gated on its line: if the line cannot be
  written the response is 503 and nothing is sent. Sabotages 1414 to 1417 and 1431 to 1435.

- **Fixed: a `:viewer` could create, edit and delete CRM contacts.** `CRM.Person` create, update and destroy (archive and
  restore included) were `OrgScope` only; they now carry the member-or-above gate `Company` has. Reads and `reveal_person`
  are unchanged. The in-app sample-data offer is pinned to the same bar by a test. Every screen that writes a Person now
  acts as the signed-in person, so the gate holds end to end: the contacts list, the contact detail page (edit, delete),
  the CSV import (Person and any other member-gated resource of the mounted domain) and the leads lens. Tests log in
  as a real viewer and a real member and assert the database. Sabotages 1418, 1419 and 1427 to 1430.

- **Fixed: the Support, Billing and Marketing pages acted as a fixed `:member` (so a `:viewer` created and changed tickets,
  authored knowledge-base articles and created customers), and a billing page opened by an admin kept its admin actor after a
  demotion.** These pages now act as the signed-in person (their membership role), show the denied or the unavailable state,
  reading nothing, when there is no active membership or the lookup fails, and re-resolve who acts before every event, so a
  member suspended or demoted while a page is open is judged by the membership as it is now: the ticket inbox, ticket page
  (status, conversation, reply) and knowledge base; billing overview, invoices, plans, dunning, usage and settings; marketing
  campaigns, campaign (compose and send) and segments. **Roles:** ticket, conversation and status writes are member-or-above
  (the kernel already said so); a reply, authoring or editing a KB article and creating a billing customer are member-or-above
  (the message, article and customer resources only check the org, so the page now checks the role); publishing a KB article,
  every subscription, plan, price, invoice and entitlement write, every campaign and segment write, subscribing and opening
  the payment portal are admin-or-above, and so is sending a campaign to a segment (consent and suppression are still
  enforced). The pages offer a write control only to a role that can use it (`:can_write` for member-ranked controls, the new
  `:can_admin` for admin-ranked ones); reads stay open to every active member. **Upgrade notes:** host code and tests that
  drove these pages without a signed-in person on an armed host now get the denied state; log in as a real person with the
  right role. A host that called `Samen.Web.Support.KbReads.publish_article/3` with an org id is unchanged; it also takes a
  `%Samen.Scope{}` now, which the page passes so a member's publish is refused. `Samen.Web.TenantActor` gains
  `write_scope/3` (the acting scope on an armed tenant plane and nothing else: anything that is not a `%Samen.Scope{}` raises there; only the disarmed dev posture and the operator plane get the posture's admin elevation (superseded: the operator plane now
  answers a read-only scope; see "Changed: a tenant page on the operator plane is read-only")),
  `administrable?/2`, `admin?/1` and `member?/1`. No migration. Sabotages 1528 to 1536.

- **Fixed: the rest of the CRM pages and the Work pages acted as a fixed `:member`, and a `:viewer` could enroll contacts into
  email sequences.** These pages now act as the signed-in person (their membership role), and show the denied or the
  unavailable state, reading nothing, when there is no active membership or the lookup fails: the CRM company detail page
  (edit, delete, billing link, log activity), pipeline, calendar, dashboard, mailbox, contacts gallery and sequences (enroll),
  and the Work tasks list, task detail (status), projects (create, archive), timeline and task tree. A viewer could create and
  archive tasks and projects and edit and archive companies through them; they now get a refusal. **Policy gate added:**
  Outreach `Enrollment` `:enroll`, `:pause`, `:resume` and `:stop` had no role rule (org scope only) and are now
  member-or-above, like the other CRM and Work writes (`Sequence` writes and `Enrollment` destroy stay admin; reads are
  unchanged; the system actions are closed to actors in the next entry). **Upgrade note:** a host that enrolls or pauses enrollments with a `:viewer` actor (or with
  an actor carrying no role) now gets a forbidden error; run those as a member or above, or with `authorize?: false` in a job.
  No migration. Sabotages 1470 to 1478.

- **Fixed: an open page kept the role it had at its last navigation.** A member suspended or demoted while a converted page was
  open could keep sending write events (create, delete, enroll, status change, restore, CSV import) and they ran with the old
  role: every handler reused the scope resolved at the last `handle_params`, and so did the list context and any form built at
  load. `Samen.Web.TenantActor.assign_actor/2` now attaches a `:handle_event` lifecycle hook (once, ahead of the `ListLive` hook
  and the view's own `handle_event/3`) that resolves the person again for the page's org before EVERY event. Still acting:
  `acting_scope`, the list context and the forms built at load follow the current role, so a demotion takes effect on the very
  next event. Denied or unavailable: the page switches to the refused state and the event is halted. The refused state carries
  no data: the list context and page are cleared and the view runs the same load a refused navigation does (an optional
  `actor_lost/1`), so a record's name in a topbar (the company, the contact's full name, the task title), the forms, the tiles
  and the profile are dropped, and the profile shows the refused card for the unavailable state too. This covers the tasks, task, projects, company, contact, contacts, companies, sequences and CSV import pages and the
  other converted pages through the same call; the notification inbox (events and realtime messages) and preferences resolve the
  recipient their own way and carry the same guard. Cost: two identity queries per event (the user, then the membership),
  re-read every time, never cached across events. The refused card gains a "Check again" button (`retry_actor`) that resolves
  the person again and reloads the page when they act; a page with no URL to go back to (an embedded view, or one whose org
  resolved late) reloads in place (`actor_regained/1`) instead of doing nothing. A view that builds something from the scope
  exports `actor_changed/1`. The Edit contact button follows the write role like the other pages' controls. The generated
  `--live` index and form screens had the same bug (they submitted a form built at load with the role of that moment) and now
  attach the same guard; **upgrade note:** re-generate (`mix samen.gen.resource --live`) to get it, an already generated
  screen keeps the old behavior. No migration. Sabotages 1479 to 1483 and 1502 to 1507.
- **Fixed: viewers were offered write controls, a refused request still wrote, and a missing company crashed its page.**
  The create, edit, delete, enroll and status controls of the company, contact, companies, contacts, tasks, task, projects,
  sequences and import pages are shown only to a person who may write (`Samen.Web.TenantActor.writable?/2`: the plane AND at
  least the member role, assigned as `can_write` so a replay shows the controls its person saw); what the pages allow is
  still the kernel policy. A viewer's billing-link request no longer registers
  the org's custom field before the update policy refuses it (`link_billing_customer` asks the policy first). `edit_company`,
  `validate_edit` and `save_edit` (and the contact twins) for a record that was not found are no-ops instead of a crash.
  Sabotages 1493 to 1495 and the viewer tests for the forms built at load (1484, 1485; 1473 is the event-time mutation alone).
- **Fixed: Outreach system actions were open to every actor, and Mailbox rows to every tenant actor.** `Enrollment`
  `:advance_due`, `:due_scan` (an unfiltered cross-org read) and `:system_advance`, and `StepSend` `:queue`, `:mark` and
  `:requeue`, were `authorize_if(always())`. The four internal ones (`:system_advance`, `:queue`, `:mark`, `:requeue`) are forbidden to every actor and keep working as the
  `authorize?: false` calls `Samen.Sequences` and the send worker make; `:due_scan` and `:advance_due` are authorized only for
  AshOban's own interaction (the `:sequence_step_due` trigger). Mailbox `Connection` and `MailMessage` writes were org scope
  only; the sole writer is `Samen.Mailbox.Sync` (`authorize?: false`), so create, update and destroy are now forbidden to every
  actor. `reveal_connection` and `reveal_mail_message` checked the reveal grant for a caller-supplied `actor_id`, so any actor
  could name an operator who holds a grant and ride it: the argument is gone and the grant is checked for the actor that runs
  the action. **Upgrade note:** a host that wrote Outreach system actions or mailbox rows with a tenant actor, or passed
  `actor_id` to a Mailbox reveal action, gets a forbidden or an unknown-argument error; run those as the system
  (`authorize?: false`) or as the actor that holds the grant. No migration. Sabotages 1486 to 1492.

- **Fixed: every generic `reveal_*` probe action trusted a caller-supplied identity and answered anyone.** The 19 probes
  ("does that id hold a live reveal grant on this subject?": CRM `reveal_person`, Identity `reveal_user` and
  `reveal_invitation`, Billing, Marketing, Support (2), Automation, Primitives (2), AI `reveal_agent_run`, Chat (2), the
  `demo`, `driftwood` and `pawchart` hosts, and the three generator templates) took an `actor_id` argument and were
  `authorize_if(always())`, so any code path, with any actor or none, could ask about anyone's grants. They are now one
  implementation, `Samen.Reveal.GrantProbe` (the Mailbox pair uses it too): the grant is checked for the actor that RUNS the
  action, a missing actor is denied, there is no identity argument, and the policy is `authorize_if(actor_present())`. A
  declared reveal action (`reveal :name` in `pii do`) now fails the build unless it has exactly this shape:
  `run({Samen.Reveal.GrantProbe, _})`, arguments exactly `[:subject_id]`, and a `policy action(:name)` whose only check
  is `authorize_if(actor_present())`; any other `authorize_if` or `authorize_unless` that can apply to it (`always()`,
  `expr(true)`, a custom check, in a `policy`, a `policy_group` or a `bypass`) and any `bypass` other than AshOban's own
  interaction are refused. `Samen.Transformers.RevealActions` enforces it at compile time on every resource that
  declares a reveal action, so hosts and
  generated apps get it with no CI step (`Samen.Pii.Info.reveal_probes_examined/1` records what it examined). **Upgrade
  note:** drop `actor_id:` from any call to a reveal probe action (it is now an unknown-argument error) and run it with the
  actor that is asking; a reveal action of your own that is not of that shape stops compiling,
  so give it `run({Samen.Reveal.GrantProbe, label: :field})`, the one argument `subject_id`, and `authorize_if(actor_present())`; **re-generate** (or
  copy) the `vertical.ex` / `--api` / `--live` resource templates. No migration. Sabotages 1508 to 1511 and 1517.

- **Fixed: the Automation and AI-agent system actions were open to every actor.** Workflow `:scan_due` and `:dispatch_due`,
  Reminder `:due_scan` and `:fire`, Escalation `:due_scan` and `:advance_step`, and the agent Run `:due_scan` and
  `:resume_due` were `bypass … authorize_if(always())`, and each `due_scan` is a read with no org filter, so any actor could
  read every org's due rows and run the trigger's write. They are now authorized only for AshOban's own interaction (the
  triggers keep working) and forbidden to every actor. Workflow `:operator_kill` and `:operator_rearm` were open to every
  actor too; they are forbidden, and both callers (`Samen.Automation.Health`, after its operator-role gate, and the rate
  breaker) already run `authorize?: false`. The automation Run log's `:create` and `:update` bypass is forbidden to actors
  (the kernel pipeline writes it as `authorize?: false`). The agent Run's `:expire_due` (the `:agent_proposal_expiry`
  trigger) is the scheduler's like its siblings, and every other agent Run write (`:advance`, `:park`, `:cancel`, …) is
  forbidden to actors: `Samen.AI.Agent` runs them all as `authorize?: false`. Escalation's `:open`, `:refresh`, `:resolve` and `:cancel` were open to every actor with
  no org check; they are forbidden too (`Samen.Automation.Escalate` runs them as `authorize?: false`). **Upgrade note:** a host that ran these actions, or wrote Run rows,
  with a tenant actor gets a forbidden error; run them as the system (`authorize?: false`) or let the trigger run them.
  No migration. Sabotages 1512 to 1516 and 1518 to 1521.

- **Fixed: `Samen.Webhook.deliver/4` raised `FunctionClauseError` on any non-empty endpoint list, discarded the `:multi` it
  was given, and answered `{:ok, 0}` when no `:endpoints` were passed.** It now enqueues one job per active, subscribed
  endpoint. With `:multi` it returns `{:ok, count, multi}`: **upgrade note:** run the RETURNED multi (`Ecto.Multi` is
  immutable, so the multi you passed in never held the jobs). Without `:endpoints` it reads the record's org rows from the
  `:webhook_endpoint_module` on `:webhook_repo` (or `:repo`); with neither configured it returns `{:error, :not_configured}`
  and a failing lookup returns `{:error, :endpoint_lookup_failed}`, where it used to claim `{:ok, 0}`. The lookup reads only the
  org's UNARCHIVED rows (a raw query does not get Ash's archive filter, and archiving leaves `status` alone, so an archived
  endpoint still `:active` would otherwise have received payloads). A failed enqueue is
  `{:error, reason}`. Nothing in the framework or the three hosts calls `deliver/4` today. Sabotages 1387 and 1388.

- **Fixed: a member could un-quarantine a File.** `status` was an input of the generic `File` `:create` and `:update`, so
  `%{status: :active}` from any member skipped the scan that `Samen.Files.promote/3`, `previewable?/1` and `fetch_bytes`
  rely on. `status` is no input of any actor write now (a new row is `:quarantined`); the scan-gated `Samen.Files.promote/3`
  sets `:active` through a new system action `File :promote` that no actor, an admin included, may run. `archived_at` is no
  input of `File :create`/`:update` either (use `:archive` and `:restore`). `File :update` takes `filename` and `metadata` only (plus
  `storage_key` and `org_id`, which `ChokepointGuard` and the org pin still refuse to change): `content_type`, `size_bytes` and
  `uploaded_by_id` are facts the upload records, and the byte route serves with the stored content type, so a writable one let a
  member turn a scanned text file into `text/html` or javascript and skip the type and size checks. **Upgrade notes:** code that
  rewrote `content_type`, `size_bytes` or `uploaded_by_id` through `File :update` must go through `Samen.Files.upload/3`; a host or test that wrote
  `status:` through `File :create`/`:update` must use `Samen.Files.promote/3`; to archive or restore a file use the
  archive and restore actions, not `archived_at`. Sabotages 1371, 1372, 1392 and 1393.

- **Fixed: notifications were readable and writable across recipients.** `Notification` and `NotificationPreference` were
  `OrgScope` only, so a viewer could create, update or destroy any recipient's notification, any member could read every
  notification of the organisation, and any member could write another user's `NotificationPreference` and switch their alerts
  off. New check `Samen.Policy.RecipientOnly`. Now: a user reads and marks read only their own notifications (and, for a
  member or above, the rows the engine addresses to the organisation, `recipient_id == org_id`); the operator plane still reads
  the org's rows, masked; no actor creates a notification (`Samen.Notifications.Engine` creates them with `authorize?: false`);
  only the recipient or an org admin destroys one (a row addressed to the ORGANISATION is one shared row: destroying it needs an
  admin; marking it read stays a member's, as before, and is shared state); nobody edits another recipient's notification, and
  an update takes only `read_at` and `status`, with `status` only ever set to `:read` (the one transition the inbox performs). A user creates, updates and destroys only their own `NotificationPreference` (an admin included
  gets no exception: no screen needs one), and its `recipient_id` is not editable. In `samen_web` the inbox and the settings
  panel act as the signed-in user, derived from the SESSION: the framework login (`POST /login`, which writes
  `samen_session_token`) or the legacy BYO session user resolves, through `Samen.Auth.OrgActor` (`Samen.Web.Settings.Reads.actor_in_org/3`),
  to the per-org `Identity.User` id AND the member's real role (so a viewer is a viewer there, not a member). A principal with no
  ACTIVE membership in the org gets no access, and a failed lookup is an error state on the page, never an empty inbox: a realtime
  notification on such an inbox reads nothing and sets no unread count. The
  `:recipient_id` mount label no longer names a recipient, the `:current_user_id` label and the `?recipient=` and `?user=`
  parameters are dev legs honoured only in the disarmed posture, and a session that resolves no user (a disarmed dev host) sees
  the org-addressed rows only and says so. The other settings screens (profile, security, API keys, invitations, reveal
  approvals, billing settings, onboarding, replay) now find the framework-login user too, through `Settings.Reads.current_user_id/3`,
  and when `?org=` switches them to another org they re-derive the user for THAT org (`Settings.Reads.reresolve_user/3`; no active
  membership there is the no-user state), never keeping the id of the org they mounted on.
  Chat @-mentions are addressed to the mentioned participant's per-org user (`principal_id` of a `:user` participant, which
  `Chat.start_conversation/3` takes from the session), not to the participant row: a participant with no per-org user (an
  operator-staff participant, or one added without a `principal_id`) is not notified, and the mention preference is keyed on the
  user id, so its owner can manage it. **Upgrade notes:** a host that created notifications or preferences with an actor must
  use the engine or `authorize?: false`; a host that showed the whole org's notifications to every member now shows each
  member their own plus the org-addressed ones; a host that wired the `:recipient_id` or `:current_user_id` mount label must sign its users in through the
  framework login or the legacy session user (the labels are dev-only now); code that added a chat participant meant to be
  mentioned must pass `principal_id` (the per-org user id); code that destroyed an org-addressed notification as a member needs
  an admin, and code that wrote a `status` other than `:read` through `Notification :update` must use the engine. Sabotages 1373 to 1376, 1384 to 1386, 1389 to 1391 and 1398 to 1401.

- **Fixed: an armed host redirected every framework login to `/login`.** The host `:browser` gates `DriftwoodWeb.Auth` and
  `PawChartWeb.Auth` admitted only the legacy `samen_current_user` session key, but the framework login (`POST /login`) writes
  only `samen_session_token`. A live spine session is now an authenticated principal there too; an unknown, revoked or expired token is
  not. **Upgrade note:** a host that copied these gates must add the same clause. Sabotages 1396 and 1397.

- **Fixed: a Tagging accepted any subject, including an id from another organisation.** `subject_key` and `subject_id` were
  plain scalars checked only by `Samen.Web.Tags.attach/5`, so a direct `Ash.create`, the automation `add_tag` action or a
  host's own code could anchor a tag to a nonexistent object or to another tenant's row. New change
  `Samen.Policy.SubjectInOrg` on `Tags.Tagging`: `subject_key` must resolve (the `Samen.ObjectKey` rule, under the Tagging's own
  host namespace) to a compiled resource with an `org_id`, and the row must exist in the write's organisation, read on the
  write repo; a lookup that cannot run refuses the write. It holds on `authorize?: false` writes too. **Upgrade note:** code
  or seeds that tagged a made-up subject (a key no resource answers to, or an id with no row) now get an error; tag a real row
  of the same organisation. An ARCHIVED subject row is refused too, as `Samen.Web.Tags.attach/5` always did (its resolve reads
  through Ash, which hides archived rows), and a client-supplied key never creates an atom (`Module.safe_concat`). The check is
  existence in the organisation, not the subject's own read policies: the web helper still resolves the subject under the
  viewer's scope first, but a direct write or the automation `add_tag` action is not held to the subject's read policies.
  Sabotages 1377, 1378, 1394 and 1395.

- **Fixed: an admin's direct `Analytics.ProductEvent :append` bypassed every gate `Samen.Analytics.track/1` applies** (registered
  event name, catalogued prop keys, no PII-shaped `entity_ref` or value). `:append` is now the system door only: no actor, an
  admin included, may run it, and `track/1` (which writes with `authorize?: false`) is the one way a `pae` row is written.
  **Upgrade note:** code that appended product events with an actor must call `Samen.Analytics.track/1`. Sabotage 1379.
- **Fixed: `Primitives.SearchIndex` could register a vault-routed field.** The create never ran `SearchIndexGuard` (only the
  query path did). Create and update now refuse a `resource_name`/`field_name` that names a `pii_attribute` of the resource
  (or its storage column), and refuse a `resource_name` that is not a loaded Ash resource, on every path including
  `authorize?: false`: a resource whose PII declarations cannot be read is never registered. **Upgrade note:** a search index
  row naming a resource module that does not exist is now an error. Sabotages 1380 and 1381.
- **Fixed: a calendar event could end before it starts.** `Calendar.Event` create and update refuse `ends_at` earlier than
  `starts_at` (equal instants are allowed; no end is allowed). On an update that changes only one of the two, it is compared
  against the stored other; a stored value that cannot be read refuses the write. **Upgrade note:** an existing event whose
  stored end precedes its start can still be edited in other fields, but an edit that touches either instant must leave
  them ordered. Sabotage 1382.
- **Fixed: a saved view could store typed filter-box text for a vault-routed field, and its documentation overstated what is
  refused.** `Samen.Web.SavedViews.Params.serialize/4` now refuses (`{:error, {:vaulted_field, field}}`) a non-empty
  filter-box text when any of the surface's `filter_fields` is vault-routed, and `restore/2` drops such a stored text. The
  moduledocs now say exactly what is stored: the filter-box text of a surface whose filter fields are all non-vaulted, and
  structured predicate values on non-vaulted fields, are stored as typed; no PII detection is attempted on them. Sabotage 1383.

### Security: identity authorization, round 3 (role management, sessions, invitations, org slugs and API keys)

- **Fixed: an admin could demote, suspend or re-role an owner or a peer admin.** `Samen.Policy.ManageRole` judged only the
  role a membership write was SETTING, so `%{role: :member}` (or `status: "suspended"` together with a lower role)
  passed for an admin against an owner's or another admin's row. A write on an existing membership (update, destroy) must
  now out-rank BOTH the role the row holds in the database and the role being set. The stored role is read by primary key
  on the write repo, never from the record in hand (which may be stale or carry `%Ash.NotLoaded{}` for `role`); a row it
  cannot read refuses the write. `Samen.Scope.Role.may_manage?/2` is strict, so an owner cannot demote, suspend or remove
  another owner either: no update or destroy of an owner's membership passes `ManageRole`. A caller that relied on an admin
  editing an owner's or a peer admin's membership now needs an owner (for an admin) or no longer can (for an owner).
  Sabotages 1322 and 1323.
- **Fixed: an admin could demote an owner or a peer admin by adding a second, lower membership row.** The session resolver
  takes a user's lowest-ranked active membership in an org, so `Membership :create` for an existing member's `user_id`
  with role `:viewer` made that member resolve as a viewer, and the member could not remove the row (that needs an
  admin). `Membership :create` now refuses when a row for the same `org_id` and `user_id` exists, on every path including
  `authorize?: false`, and refuses when that check cannot run. Registration, OIDC link, invitation accept and the operator
  seeds each create the user and its one membership together and are unaffected. **Upgrade notes:** code that created a
  second membership for a user in an org now fails with `already has a membership in this org`; change the existing
  row's role or status instead. Sabotages 1334 and 1335.
- **Fixed: `ManageRole` did not see a role set through `Ash.Changeset.atomic_update(:role, …)`.** An admin could make a
  member an owner that way. The check now refuses (errors) any write that sets `:role` through the changeset's atomics.
  Sabotage 1336.
- **Fixed: a suspended member kept their role and their org in an existing signed-in session.** A membership whose
  `status` is not `"active"` (suspended, invited) now confers no role and no org access, the rule an API key's acting role
  and the settings role lookup already applied. `Samen.Auth.OrgActor.active_membership/3` (the
  lowest-ranked ACTIVE membership of a user in an org, `:none` otherwise) now decides `resolve/3` and `resolve_result/3` (the
  session actor's role), `Samen.Scope.ApiKey.membership_for_user/3` (an API key's minter), `authorized_org_ids/2` and `authorized_org_ids_result/2` (the orgs a session may act in, so the org
  switcher and `?org=` no longer reach an org the member is suspended in; it reads every active membership of the
  credential's users in one query), and `Samen.AI.Agent.Approver` (a suspended
  member can no longer approve an agent action). `PawChart.Auth.authorized_org_ids/1` filters on `status == "active"`.
  A suspended user whose only org is the suspended one resolves no org, the same answer as a credential with no
  membership. `Samen.Policy.ManageUser` still ranks a suspended target by its role, on purpose: an admin cannot suspend
  an admin to get around the rank rule. **Upgrade notes:** `authorized_org_ids/2` now needs an active membership as well
  as a `User` row in the org; a host seam that lists orgs from its own membership table must filter on
  `status == "active"` too.
  `ManageRole` returns an error tuple (not `{:ok, false}`) when it cannot read the stored role. Sabotages 1324 to 1327.
- **Fixed: the session cap evicted a live session because of an abandoned expired one.** `Samen.Auth.SessionCreate`
  counted every unrevoked session toward `Org.max_concurrent_sessions`, expired ones included, so with a cap of 2 an old
  session still in use plus a newer expired one made the next sign-in revoke the in-use session. Only sessions that can still
  resolve (unrevoked and not past `expires_at`) count toward the cap now. **Upgrade notes:** none; a credential that sat at its
  cap with expired sessions now keeps its live ones. Sabotage 1328.
- **Fixed: a direct `Invitation` create could set any `status` and left no expiry.** The default `create: :*` accepted the
  public `status` (an admin could create an `"accepted"`, `"revoked"` or junk row) and left `expires_at` empty. `Invitation :create` now accepts `org_id`, `role` and `email` only, and
  every create is `pending` with the 14-day expiry (`Samen.Identity.Invite.ttl_seconds/0`); `Samen.Identity.Invite.create/3`
  keeps setting only the credential-class columns (`token_digest`, `email_bidx`) on top. The default create does not set
  either of them. **Upgrade notes:** code that created
  an invitation directly with a `status:` input now fails with a no-such-input error; use `Samen.Identity.Invite.create/3`.
  Sabotages 1329 and 1330.
- **Fixed: an org admin could set its slug to another org's slug or id.** `Samen.Identity.SlugFree` guarded only
  `Org :open_account`, yet the operator console joins an account's admins, customer, subscription and tickets by
  `org.slug`, so two orgs sharing a slug (or one org's slug equal to another's id) each showed the other's admins, customer, subscription and tickets. `Org
  :update` and `Org :create` now apply the same rule: a slug being set must not be another org's slug or id (an update never collides with the org's own row; slugs are compared trimmed and case-insensitively, so `Acme` and
  ` acme ` collide with `acme`; a check that cannot run refuses the write). **Upgrade notes:** a rename or create onto a
  taken slug now fails with `slug is already taken`. Sabotages 1331 and 1332.
- **Fixed: `ApiKey :mark_used` could be written by an authorized admin.** The action stamps `last_used_at`, the evidence that
  a key was presented, and the admin-gated update policy let an org admin or owner set it to any time. It is now a
  system action: no actor may run it, and the key check's internal `authorize?: false` call (the demo plug, the hosts'
  tests) is unchanged. **Upgrade notes:** a host that stamps `last_used_at` for an actor must do so from its key check
  with `authorize?: false`. Sabotage 1333.

### Security: authorization and erasure, round 4

- **Fixed: an in-org actor could move a row into another organisation, or file one under a foreign `org_id`, on any
  resource.** `org_id` is a public, writable core attribute and `Samen.Policy.OrgScope` filters the pre-image of an
  update only, so every resource whose actions accept `org_id` (every `defaults([update: :*])` resource: CRM, billing,
  support, CMS, work and the host-written ones) let an authorized update write the row into another tenant, and a
  resource whose create policy did not bind `org_id` let an actor create into one. `Samen.Transformers.OrgIdPinned`
  now adds `Samen.Policy.OrgIdPinned` to every resource that has an `org_id`: an authorized update cannot change it
  (an input, or any change an action makes), and an actor's create must carry the actor's own `org_id`. Code running
  with `authorize?: false` (seeds, `Ash.Seed`, `force_change_attribute` in a system path) is unaffected.
  **Upgrade notes:** an update that sent `org_id: <the same org>` as input now fails (`org_id cannot be changed`): drop it.
  An update that needs `org_id` on the record (custom-field validation) loads it with `Ash.load!(record, :org_id)`.
  `Samen.Policy.SameOrgFk` now reads a record's stored `org_id` when the record in hand has it unloaded, where it
  previously skipped the check. It does so only on an update that actually writes a foreign key (any other update
  costs no query), through the WRITE repo (`:mutate`, the caller's transaction, never a read replica), matching every
  primary-key column (a composite key reads exactly its own row). A row whose stored `org_id` cannot be found refuses
  the foreign-key write (`same-org FK check could not read this record's org_id`); it never skips the check.
  Sending the value a row already has as `org_id` passes only when the record in hand has `org_id` loaded; with it
  unloaded the write is refused, because the pin cannot tell the value is unchanged (load it with `Ash.load!/2`).
  `Samen.OrgIdPinnedGuard.walk/2` is the walk the per-host guard tests use.
- **Fixed: `Samen.Web.Settings.Profile.update/4` took the identity of whatever user id it was passed.** It rewrote the
  scope's actor to that id, so a viewer's scope plus another user's id passed `ManageUser`'s own-row branch. It now
  refuses (`{:error, :forbidden}`) unless the scope's actor IS the user being edited; `ProfileLive` builds that scope
  from the session-resolved user (`Samen.Web.Settings.Reads.user_scope/3`), and an operator-plane scope is never given a
  user identity. The profile masking proofs again reach `Samen.Pii.WriteGuard`: they use an operator-plane actor
  that is the edited row, which `ManageUser` allows, so only WriteGuard can refuse the vaulted write, and they assert
  its error. Sabotages 1312 and 1313; 11 re-anchored.
- **Fixed: the `org_id` pin was decided once, when the changeset was built.** A changeset built with `authorize?: false`
  and then run authorized moved a row to another org. `Samen.Policy.OrgIdPinned` now also re-checks in a
  `before_action`, from the authorization the action actually runs with. A changeset built normally and run with
  `authorize?: false` (the notification digest's pattern) is system code at run time and is not re-checked then; an
  `org_id` change on it is still an error from the build, so that pattern behaves exactly as before. An authorized
  upsert that would rewrite `org_id` on a conflicting row, on an identity that does not include `org_id` (an action
  declared `upsert?`, or a run naming `upsert_identity:`), now carries an upsert condition `org_id = <actor's org>`:
  it still updates a row of the actor's own org, and no longer updates another org's row that merely shares the key.
  A run-option upsert on the primary key alone is indistinguishable from a create and is not covered. An atomic
  update whose own change writes `org_id` after the pin looked is refused too (a guard test, not a fix: it already
  was). Sabotages 1317, 1318.
- **Fixed: `Samen.Policy.ManageUser` passed an admin for a target with no id** (the template record of a bulk or
  query-based write), reading it as a membership-less viewer. It now refuses. No bulk User write exists today.
- **Fixed: a viewer could edit another user's handle, name and emails, suspend an admin, or reactivate themselves; any
  in-org actor could create or destroy a user row.** `Identity.User` writes rested on `OrgScope` alone. A user now edits
  their own profile fields; changing another user's row, anyone's `status`, or destroying a user needs the rank rule
  membership updates use (`Samen.Policy.ManageUser`: at least `admin` and strictly above the target's highest membership
  role in the org; nobody changes their own `status` or destroys themselves), and creating a user row needs `admin`.
  **Upgrade notes:** `Samen.Scopes.Identity.Blueprint.define_user` takes the membership module (the `use
  Samen.Scopes.Identity` mount passes it, so mounts are unaffected). A screen that edits a profile must act as the user it
  edits: `Samen.Web.Settings.Profile.update/4` refuses (`{:error, :forbidden}`) any scope whose actor is not the user
  being edited, so build the scope with `Samen.Web.Settings.Reads.user_scope/3` from the identity the session resolved
  (`ProfileLive` does). It never rewrites the actor itself. A test that
  changes a user's own `status` as that user must act as an admin over a lower-ranked user instead.
- **Fixed: erasing a principal account could leave a keyed hash of the erased person's email in place.** The blind-index
  arm only ran for specs a host had installed (`Samen.Erasure.install_default_specs/1` at application start), so a host
  that did not call it reported a successful erasure with `email_bidx` still matching the email if the person
  re-registered, and no host cleared the `Identity.LoginFailure` counters keyed on that index. The arm now derives its
  specs from the host's live schema at erasure time (`Samen.Auth.BlindIndexErasure.derived_specs/1`: Credential and
  Invitation `email_bidx`, AuthToken `sent_to_bidx`), and purges the login-failure counters keyed on the erased index
  and on the credential id. A per-tenant data-subject shred still leaves the shared credential alone. `uncovered/1` and
  a per-host guard test assert every blind-index column is covered, through the same domain lookup the runtime uses.
  An invitation is the inviting organisation's own record with its own subject (ADR-046 section 4.1, decision 1b): a
  principal-account erasure clears the person's credential index and does NOT reach the invitations other
  organisations addressed to that person (their `email_bidx` and email vault rows stay until the invitation itself is
  erased as a subject, which does tombstone its index).
- **Fixed: an erasure that could not clear a blind index destroyed the subject's key and only then failed.** The
  coverage check now runs BEFORE anything irreversible (`Samen.Auth.BlindIndexErasure.plan/1`, called first by
  `Samen.Erasure.shred/2`): an unregistered `_bidx` column returns `{:error, {:blind_index_uncovered, [{resource,
  column}]}}`, and a derivation that finds no resources at all returns `{:error, {:blind_index_no_resources,
  lookup_options}}` (the `:resources` / `:domains` / `:otp_app` that were given), instead of reading as "nothing to
  clear". Either way the key is live, nothing is sealed and no report is written, so the operator fixes
  the registration and retries. `shred/2` takes `:resources`, `:domains` and `:otp_app` for that derivation; an explicit
  `:bidx_specs` list is the caller's own scope and is neither derived nor checked. `Samen.Retention`'s shred sweep
  reports any refused or failed shred through `Samen.Observability.Failure` (`write=retention_shred`, the error tag,
  the subject's record id) every sweep, and never counts that subject as erased.
- **Fixed: a subject export decrypted authentication secrets.** `Samen.Dsar.export_subject/2` walked every vault row of
  the subject id, and a Credential vaults its TOTP secret and recovery-code digests under `:pii_secret` keyed on the
  credential id, so a tenant-plane export of that id returned them in clear. Authentication secrets are never part of a
  subject export: the walk excludes secret-class vaults (`Samen.Vault.Class`, `:pii_secret` plus any host vault under
  `config :samen_core, :secret_vaults`), decided by the vault a field is routed to and never by its name.

### Security: identity authorization (evaluation 2026-11-13, findings 1, 5, 7, 10, 13, 16)

- **Fixed: any in-org actor could raise a pending invitation to `:owner`, or reopen a revoked one.** `Invitation`'s
  generic `:update` accepted `role` and `status` on org scope alone. `:update` now takes no input and is forbidden to
  every actor; the lifecycle moves only through `:accept`, `:revoke` and `:expire`.
- **Fixed: an admin could mint or edit an API key acting as `:owner`, clear `revoked_at`, or push `expires_at` past the
  365-day ceiling.** On the `ApiKey` resource: create is bounded by `Samen.Policy.MinterRoleCeiling` (actor role >=
  `minter_role`, role required); `Samen.Scope.ApiKey.ClampExpiry` clamps every write that sets `expires_at`; `:update`
  accepts `expires_at` only; revocation is the new one-way `:revoke` action (`Settings.ApiKeys.revoke/3` uses it).
  `Driftwood.Freight.ApiKey` gets the same ceiling and `:revoke`.
- **Fixed: pawchart's MCP resolver authenticated expired keys and promoted a role-less key to `:member`.** The digest +
  not-revoked + not-expired lookup is now `Samen.Scope.ApiKey.active_query/3`, used by demo, driftwood, pawchart and the
  generated key plug; `Samen.Scope.ApiKey.acting_role/1` refuses a key with no real role.
  **Upgrade notes for generated apps:** re-generate or hand-apply `lib/<app>_web/api/key_auth_plug.ex` (the lookup becomes
  `Samen.Scope.ApiKey.active_query(<App>.Operator.ApiKey, digest, now)`; the `# authz-scope:` marker stays on the read);
  any custom key check should do the same. Code that revokes a key through `:update, %{revoked_at: ...}` must call
  `:revoke`; code that sets `Org.org_id`/`plan`/`onboarded_at` through `:update` input must `force_change_attribute` it.
- **Fixed: a viewer could update or delete its own organization.** `Org` update now needs admin+ and destroy needs owner
  (`Samen.Scope.Role`: owner has "full control, including destroy"; the ADRs are silent, so admin-for-update is a
  decision). `Org.:update` accepts `name`, `slug` and `max_concurrent_sessions` only: `plan` and `onboarded_at` are no
  longer inputs, and `Samen.Web.Onboarding.select_plan/4` force-sets a plan it validated against the host's choices. The
  onboarding wizard now acts with the caller's real membership role instead of a hardcoded `:member`.
  Sabotages 1246-1255.

### Security: identity authorization, round 2 (review of the round above)

A read-only review of the work above found that several of its claims did not hold. Each finding was reproduced with a
red test through the real authorization path (a `scope:`/actor, never `authorize?: false`) before it was fixed.

- **Fixed (blocker): `ApiKey :update` extended live keys and revived expired ones**, so "never extends" was false: `nil`
  became `now + 90d`, any later time was accepted, and an admin could do it to an owner-rank key. An update may now only
  SHORTEN: `min(requested, 365-day ceiling, current expires_at)`; `nil` keeps the current value; a legacy row with a
  `nil` expiry may be given a clamped one (the only direction open to it); an already-expired or revoked key refuses
  every update. `MinterRoleCeiling` stays on `:create` only, by decision: an admin shortening or revoking an owner's key
  is the permitted, desirable direction and gains nothing from it. Sabotages 1256, 1257.
- **Fixed: a key row with no `minter_role` authenticated on demo and driftwood with `role: nil`** and passed
  OrgScope-only resources. All four key-check sites (demo, driftwood, pawchart, the generated plug) now call
  `Samen.Scope.ApiKey.acting_role/1` and refuse such a key; the guard test requires it at each site. The
  `acting_role` doc now says only what is wired: no host calls `authorized?/4` at request time. Sabotages 1258, 1259.
- **Fixed: a key's actor identity was not bound to its minter.** Creating a key through an actor now requires
  `membership.user_id == actor.id`, an active membership, and `minter_role <=` that membership's CURRENT role
  (`Samen.Policy.KeyBoundToMinter`); `Driftwood.Freight.ApiKey` force-sets `minter_user_id` from the actor. An
  `authorize?: false` system or seed path remains the only way to attribute a key to someone else. Sabotages 1260, 1261.
- **Fixed: a demoted or removed minter's key kept acting with its old rank.** The acting role is the LOWER of the stored
  `minter_role` and the minting membership's current role (`Samen.Scope.ApiKey.effective_role/2`), computed at use time
  at all four sites, so no per-key sweep is needed. A key whose membership is not `"active"` authenticates no more.
  driftwood's Freight keys record a minter USER id, so the plug finds that user's active membership in the key's org
  (`Samen.Scope.ApiKey.membership_for_user/3`, `Driftwood.Operator.Membership`); a Freight key with no minter user id
  no longer falls back to a synthetic `apikey:` actor and is refused. A membership row cannot be deleted while it still
  has keys (foreign key), so suspension (`status`) is the removal that matters for Identity keys. Sabotages 1262-1265.
- **Fixed: an admin could change `Org.plan` after onboarding.** `Samen.Web.Onboarding.select_plan/4` now needs an
  OWNER (billing is the owner's, per `Samen.Scope.Role`) and refuses once `onboarded_at` is set
  (`{:error, :forbidden}` / `{:error, :already_onboarded}`); the wizard is its only caller (no other tenant path writes
  `Org.plan`). A refused choice or a member's "finish" now shows why instead of re-rendering silently. Sabotages 1266-1268.
- **Fixed: `Invitation :destroy` passed on org scope alone** (a viewer could delete every invitation, singly or in
  bulk). It now needs an admin, like `:revoke`; `:revoke` also refuses a row that is not `pending`. Sabotages 1269, 1270.
- **Fixed: `:revoke` failed OPEN on a partially selected row** (Identity and Freight): a record read without
  `revoked_at` made the in-Elixir `is_nil` check false, so the action answered `{:ok, _}` and the key stayed live. Revocation
  is now `Samen.Scope.ApiKey.RevokeOnce`, an atomic `if is_nil(revoked_at), do: now, else: revoked_at` in the UPDATE
  statement (it keeps the original instant on a second revoke). Sabotages 1271, 1272. Not tested for concurrency: a
  deterministic two-writer interleaving is not constructible in the sandbox.
- **Fixed: `Org :create` accepted `plan`, `onboarded_at` and `org_id`.** It takes `name` and `slug` only. The operator
  console's "New account" uses the new `Org :open_account` (name, slug, plan, org_id), allowed only to an actor scoped to
  the org it files the account under (`Samen.Policy.FilesUnderActorOrg`). Sabotages 1273, 1274.
- **Fixed: `active_query/3` silently skipped the expiry filter for a resource without an `:expires_at` attribute.** It
  now raises unless the resource is on `Samen.Scope.ApiKey.expiryless_resources/0` (today only
  `Driftwood.Freight.ApiKey`, which has no expiry column). Sabotage 1275.
- **Changed: the key-lookup guard test** now detects the cheap evasions (filter with the module first, an alias,
  `Ash.get`/`get_by`, an Ecto `from` on an api-key table, the revoked filter first) and keeps its control cases.
- **Tests: sabotage twins** for the Freight create ceiling, admin floor and `:revoke` (1276-1278); red tests that a
  member or viewer is refused by the wizard's Org writes.

**Upgrade notes (everything in this security series, for a host or a generated app)**

- Keys whose minter was demoted lose rank immediately; keys whose minter's membership is suspended (or, for driftwood
  Freight keys, whose minter has no active membership in the org) stop authenticating. A key with a nil or unknown
  `minter_role` is now refused at every site, including pawchart (previously it was promoted to `:member`, then
  refused there only).
- `ApiKey :update` can only shorten `expires_at`; it accepts `expires_at` and nothing else, and now REJECTS
  `scopes`, `plane`, `minter_role` and `membership_id` (a wider key is a new key). `:create` now REQUIRES `minter_role`
  and a `membership_id` that is the actor's own active membership. Anything that extended a key through `:update` must
  mint a new one.
- `Invitation :update` rejects all input, even with `authorize?: false` (system paths go through `force_change_attribute`
  on a purpose-built action); `Invitation :destroy` needs an admin; `:revoke` needs a pending row.
- `Org :destroy` is owner-only; `Org :update` needs admin+; `Org :create` accepts `name` and `slug` only (seeds and
  helpers `force_change_attribute` `plan`, `org_id` and `onboarded_at` under `authorize?: false`; the operator "New
  account" form calls `:open_account`). Any custom scope that writes the Org with `role: :member` (the old wizard pattern)
  is refused.
- `Samen.Web.Onboarding.select_plan/4` needs an owner and is closed after onboarding.
- Legacy key rows with a nil `expires_at` stay non-expiring: there is no backfill (an update may now give them a
  clamped expiry). Apps generated before this series keep working (their plug already filtered expiry, and the generated
  `api_case` mints with `minter_role`); re-generating the plug is hygiene for the first fix and REQUIRED to pick up the
  role cap and the active-membership check (`acting_role/1` and `effective_role/2`).
- Resource changes only; there is no migration. Test helpers that seed a driftwood Freight key need a real user and
  membership for `minter_user_id` (see `Driftwood.ApiCase.mk_minter/2`); an Identity key's membership must be active.

### Security: identity authorization, round 3 (second read-only review of round 2: one contract regression and holes round 2 assumed closed)

A second read-only review found no bypass introduced by round 2, but one contract regression and several holes round 2's
wording assumed closed. Each finding was reproduced with a red test through the real path before it was fixed; one did not
need a fix (item 10 below). Sabotages 1279-1296.

- **Fixed (regression): driftwood and pawchart answered a membership READ error as a bad key (401), unreported.** Both
  moduledocs promise "a lookup that fails is 503 + Retry-After, reported once". `Samen.Scope.ApiKey.membership_for_user/3`
  now returns `{:error, reason}` for a failed read (distinct from `:error`, no active membership); driftwood's key plug and
  pawchart's MCP resolver report it by name (`driftwood_api_key_membership_load`, `pawchart_mcp_key_membership_load`) and
  answer 503. Demo and the generated plug already did. Sabotages 1279, 1280.
- **Fixed: `Org :open_account` (the operator console's "New account") had no operator role floor, and its comment was false.**
  `save_new` checked no operator role, so an `:operator_readonly` operator could push the event and create an account; `plan`
  was free text; a slug equal to an existing org's slug or id created a second row under that tenant with a forged name. Now:
  `save_new` requires `Samen.Web.Operator.Authz.write_role?/1` (`:operator_admin` or `:operator_support`, the one list the
  webhook DLQ now shares); `plan` must be one the host offers (`Samen.Web.Onboarding.plan_choices/2`, the source `select_plan/4`
  validates against) or blank (the column default), so a host that wires no `:plan_labels` offers none and the plan field
  must stay blank; the resource refuses a taken slug (`Samen.Identity.SlugFree`). **The resource cannot see the operator role**
  (the console acts through the plane's synthetic `:member` scope), so the role gate lives in the console; the action
  additionally requires `context: %{samen_operator_write: true}` (`Samen.Policy.OperatorConsoleWrite`), which the console sets
  only after that role check, so a tenant viewer, member or admin calling `:open_account` directly with its own org id is refused.
  That flag is not a credential: code that can set it can already pass `authorize?: false`. Sabotages 1281-1284.
- **Fixed: a membership's org could be rewritten, and demo/the generated plug trusted the membership's org.**
  `effective_role/2` (every key-check site) now refuses a membership whose `org_id` differs from the key's, and demo's and the
  generated plug's key lookup now select `org_id` (it is not selected by default). `Membership :update` accepts `role` and
  `status` only (`org_id` and `user_id` are fixed at create; `ManageRole` is unchanged); `User :update` and `Role :update` no
  longer accept `org_id`. Sabotages 1285-1288.
- **Fixed: `ApiKey :update` judged liveness and "current expiry" from the struct in hand.** A stale struct of a key another
  actor had just retired could write a later expiry and revive it. The update now carries the filter `revoked_at IS NULL AND
  (expires_at IS NULL OR expires_at > now)` and writes `least(stored expires_at, min(requested, ceiling))` in the statement; a
  stale struct matches zero rows and the update fails. Sabotages 1289, 1290.
- **Fixed: `Invitation :revoke`'s pending check was read-then-write**, so an accept that committed in between was relabelled
  "revoked" while the membership existed. The update is filtered on `status = 'pending'` (`Samen.Identity.OnlyPending`);
  `Invite.revoke/3` answers `{:error, :not_found}` for a stale row. Sabotage 1291.
- **Fixed: `membership_for_user/3` was `limit(1)` with no sort.** Nothing forbids two active memberships of one user in one org
  (there is no unique index on `(org_id, user_id)`), so a Freight key's cap depended on row order. The LOWEST-ranked active
  membership wins. Sabotage 1292.
- **Fixed: a Freight key minted by an actor whose id is not a UUID with an active membership in the key's org was created and
  dead on arrival.** **Behaviour change:** a Freight key's `minter_user_id` must now be the UUID of a
  `Driftwood.Operator.User` with an ACTIVE membership in the key's org; creating one through an actor refuses anything else
  (old fixture-shaped ids such as `"u-1"` or `"user-N"` are refused; a seed or system path with no actor may still attribute a
  key). Freight keys are minted in tests and fixtures only, not in-product. Sabotage 1293.
- **Fixed: wizard and settings role resolution ignored membership status.** `Samen.Web.Settings.Reads.current_membership_result/4`
  (behind the plan step and the API-key, invitation, billing and reveal-approval screens) counted a suspended or invited
  membership as authority; only an active one resolves now. Sabotage 1294.
- **Changed: the expiry-less allow-list no longer lives in samen_core.** A key resource without an `:expires_at` column declares
  `def samen_key_expiryless?, do: true` itself (`Samen.Scope.ApiKey.expiry_enforced?/1`; `expiryless_resources/0` is removed).
  Demo, driftwood and pawchart each test their key-check site's resource, so a renamed column fails in CI instead of as a 500 on
  every request. Sabotages 1295, 1296.
- **Not changed (finding 10):** the per-site `acting_role/1` call is redundant with `effective_role/2`, but the guard test pins
  both calls at all four sites by string and sabotages 1258/1259 mutate that exact site-level call; removing it would force
  rewriting those patches' mutation, so it stays.

**Upgrade notes (round 3)**

- Anything that updated a Membership with `org_id` or `user_id`, or a User or Role with `org_id`, through the default `:update`
  must create the row correctly instead (or `force_change_attribute` under `authorize?: false`); role and status updates are
  unchanged.
- A key resource without `:expires_at` must define `samen_key_expiryless?/0`; the old name-based list is gone.
- Hosts that call `Org :open_account` must set `context: %{samen_operator_write: true}` after their own operator-role check
  (the console does); a host with no `:plan_labels` hook must leave the plan blank.
- Resource changes only; there is no migration.

### Added: meaning in the catalog (ADR-043 §8a)

- **Added: resources and fields carry meaning that the catalog dump and the AI catalogue expose.** Ash `description`
  on resources, attributes and relationships, a `meaning do … end` section (`label`, `synonyms`, `units`), and
  `description:` on `pii_attribute`. `Samen.Catalog.Meaning` reads it and derives `allowed_values`, `max_length` and
  the units Money, Percent and Duration fix. `schema.dict.json` gains `description` and `label` on tables, fields
  and (description) relationships, and optional `synonyms`, `units`, `allowed_values`, `max_length`; `grounding/2`
  and the MCP browse carry the same. The framework describes `id`, `org_id`, timestamps, `archived_at` and `custom`.
- **Added: a literal `vt_` in any string the catalogue entry takes from meaning, a `meaning` field naming a
  non-attribute or naming one twice, and authored units on a unit-fixing type fail compile.** The AI chokepoint
  refuses any metadata string containing `vt_`, so the check scans the reader's whole output with the chokepoint's
  own predicate (`Samen.AI.VtSentinel`): descriptions, labels, synonyms, units, `allowed_values`, and logical names.
  Physical table and column names are not meaning text and are covered by a catalogue walk test in each host.
- **Changed: the CRM scope blueprint, `Samen.Fragments.CorePerson` and demo's CRM resources are described**; the three
  committed `schema.dict.json` files are regenerated. No database column, migration or `custom_objects` change.
- **Changed: the Identity scope blueprint is described** (11 resources, 80 entries per host): org, user, membership, role,
  API key, invitation, credential, auth token, session, SSO identity and login-failure counter. Each sentence says what
  the code does at this commit and, where it differs, which path it holds for (an actor's write, the invite flow, a host
  that authenticates keys from the table); a field whose behaviour differs by host is described neutrally. The API key's
  `scopes` are described as recorded at mint, with the key's authority at use given by its effective role, and
  `last_used_at` as written only by the system-only `mark_used`. A vault field names the planes `Samen.Api.PiiResolution`
  resolves only on a resource where it is prepared. The invitation gains the synonym `invite`. `catalog_meaning.baseline`
  ceilings drop 499 to 419 (demo), 768 to 688 (driftwood) and 604 to 524 (pawchart). A demo test
  (`Demo.IdentityCatalogBehaviourTest`) runs the membership, key, invitation, slug and vault-plane sentences through the
  real actions, and `demo/test/ai_grounding_catalog_test.exs` pairs the rest with the suites that prove them. No column,
  migration or behaviour change.

### Added: generators emit described resources (ADR-043 §8a, A3)

- **Added: a generated app is correct by construction for the catalog-meaning verifier.** `vertical.ex`, `aggregate.ex`
  and the `gen.resource` scaffold describe the resource and every field they emit (name, segment, secret, label, status,
  the aggregate counters); a vault field's description describes the schema, never a value. `mix samen.gen.app` runs
  `mix samen.verify.catalog_meaning --init` right after the catalog dump, so the new app's `catalog_meaning.baseline`
  holds only the debt inherited from mounted scopes, and refuses (raises) if an entry of the app's own tables appears.
  The generated `ci.sh` runs the verifier as step 1c, after the `schema.dict.json` drift check.
- **Changed (breaking for scripts): `mix samen.gen.resource` requires `--description "…"`.** It is the resource's catalog
  description; one that would fail the verifier (fewer than 3 words, over 300 characters, TODO/TBD/FIXME, `vt_`, a
  restatement of the name, or a non-printable character / invalid UTF-8) is refused at generation time, naming the rule,
  using the verifier's own rule function (`Samen.CatalogMeaning.description_problems/2`). The generator takes no other
  field specs, so it never invents meaning for a field it cannot describe. Template syntax such as `<%= table %>` is NOT
  refused: `Samen.Gen.App.render/2` substitutes in one pass, so a value is never expanded again and the text is emitted
  as written. A description longer than 4096 codepoints is emitted whole. A description starting with `-` is passed as
  `--description="-…"`.
- **Changed: generated descriptions say only what the code enforces.** A vault field is described as read in clear on the
  owning organization's tenant plane and masked or omitted on other planes unless a reveal grant covers it (what
  `Samen.Api.PiiResolution` does; it was "masked on every read"); the same correction is made to the shared CRM Person,
  demo's Contact and the three regenerated `schema.dict.json`. `status` is "one of active, paused or archived; defaults
  to active"; aggregate and segment text names the `Samen.Aggregate` read path as where suppression happens and claims
  nothing about what fills the summary table.
- **Upgrade, for apps generated earlier:** (1) add to `ci.sh`, after the `schema.dict.json` drift check,
  `echo "--- step 1c: mix samen.verify.catalog_meaning"` and `mix samen.verify.catalog_meaning`; (2) run
  `mix samen.verify.catalog_meaning --init` once and commit `catalog_meaning.baseline`; (3) describe your own resources
  and fields (`description:` on each attribute, `resource do description … end`, `pii_attribute … description:`), then
  `mix samen.verify.catalog_meaning --shrink` and commit; `mix samen.catalog.dump --output schema.dict.json` as well.
  Scripts calling `mix samen.gen.resource` add `--description`. `--init` writes undescribed entries only: if the old app
  already has a quality violation (a too-short description, a `vt_`, a restated name), `--init` still writes the file
  but exits 1 with the violation; fix that text first (a quality violation is never baselinable) and re-run it.
  An app generated with `--no-compile` has no baseline (see `docs/guides/generators.md`), so its `ci.sh` runs strict until
  you run `--init`.

### Added: the catalog-meaning verifier (ADR-043 §8a, A2)

- **Added: `mix samen.verify.catalog_meaning`** (`Samen.CatalogMeaning`) fails a catalogued table or field with no description,
  a low-quality one (trimmed, at least 3 words, at most 300 characters, no TODO/TBD/FIXME or `vt_`, not a restatement of the
  name), bad synonyms (length, duplicates, another field's name or label, and across tables another table's label, name or
  synonym) or bad units. It fails closed on zero resources or an unreadable one, and needs no database. `demo`, `driftwood`
  and `pawchart` run it as `ci.sh` step 1c.
- **Added: `<app>/catalog_meaning.baseline`**, the exact, shrink-only list of today's undescribed tables and fields
  (demo 499, driftwood 768, pawchart 604 entries). `--init` writes it once, `--shrink` removes what has since been described,
  nothing adds to it, and a quality violation is never baselinable. The end state keeps the file at `# ceiling: 0` (a host never
  deletes it; an app with no file at all is verified strictly). `catalog_meaning_ratchet_test.exs` compares every host baseline
  with the merge base (a file missing there is tolerated only while the merge base predates the verifier, so a deleted and
  re-initialised baseline fails), refuses a baseline under an app outside its host list, and pins the exact `ci.sh` line
  `mix samen.verify.catalog_meaning` in each host.
- **Changed: `--init` and `--shrink` refuse `--domain`**: a partial discovery would write or shrink the other domains' entries away.
- **Noted: 21 of demo's 499 baseline entries are `ash_paper_trail` Version tables** (`cbl_block_versions`, `cpg_page_versions`,
  `cpt_post_versions`), generated resources an author cannot describe; they wait for framework default descriptions
  (driftwood and pawchart have none).
- **Fixed: the restatement rule no longer lets a possessive through.** "The name's name" on `name` passed because `'s` split
  off a stray "s" that counted as a new word; single letters ("s", "e.g.") are never content words now.
- **Fixed: the cross-table synonym rule no longer refuses a synonym on a twin-mounted scope.** A table with the same label as
  the synonym's own table (the twin mount of Billing or Support) is the same concept, so its names and synonyms never
  collide; a table with a different label still does.
- **Changed: `mix samen.catalog.dump` and the verifier share one domain resolver** (`Samen.Catalog.Domains`).

### Fixed: hardening batch 3 (database TLS, API-key digest uniqueness, expired API keys)

- **Fixed: a generated `--deploy` app verifies the database server certificate (ARCH-12).** `config/runtime.exs` used
  `ssl: [verify: :verify_none]`; it now calls `Samen.Deploy.db_ssl_opts/2` (`verify_peer` against the OS CA store, hostname
  checked). `DATABASE_SSL_CACERTFILE=/path/ca.pem` verifies against a private CA instead; `DATABASE_SSL_VERIFY=none` is the
  loud opt-out (a warning on stderr at every boot); any other value, a URL `ssl=` other than `true`, or
  `sslmode=disable|allow|prefer` refuses to boot, naming the variable (never the URL). The single-node lease's
  `DATABASE_DIRECT_URL` connection inherits the same options, whatever its query string says.
- **Fixed: every API-key token digest is unique.** The lookup assumes one row per digest; a duplicate made it error (a
  503). New apps create the unique index in the first migration; the committed hosts got a `CONCURRENTLY` migration
  (`concurrent_unique_index/3`, which refuses existing duplicates without printing a digest). Sabotages 1145-1152.
- **Upgrade (apps generated before these changes):**
  1. *TLS.* Edit your own `config/runtime.exs`: replace `ssl: [verify: :verify_none]` with
     `ssl: Samen.Deploy.db_ssl_opts([{"DATABASE_URL", database_url}, {"DATABASE_DIRECT_URL", direct_url}])`, and move the
     line `direct_url = System.get_env("DATABASE_DIRECT_URL")` above the `config ... Repo` call. The app then verifies the
     certificate on its next boot: set `DATABASE_SSL_CACERTFILE` (a CA file in the image) for a private CA, or
     `DATABASE_SSL_VERIFY=none` to keep the old behaviour knowingly.
  2. *Unique digest.* Run `mix samen.gen.api_key_digest_unique`, then `mix ecto.migrate`. It writes one migration of literal
     SQL (`CREATE UNIQUE INDEX CONCURRENTLY` per `*_api_key` table found in your `:ash_domains`; `--key table:column`
     names one explicitly). If a table already holds a duplicate digest the migration raises, naming the table and column,
     and deletes nothing: steps of the migration that already ran stay in place (a multi-table run may have built the
     earlier tables' unique indexes), and running it again is safe. Resolve the duplicates, run it again. A re-run
     writes nothing once every table has its index. If you ran the task before this release and it stopped with "no API-key
     table found; pass --key table:column", run it again now: its discovery looked for the logical attribute name and so
     found nothing in a real app; it had refused and written nothing, so no data was touched.
  3. *Expired keys (from the previous change in this chain).* An existing `--api` app's own key auth plug
     (`lib/<app>_web/api/key_auth_plug.ex`) must filter expired keys, or an expired key keeps authenticating. Add
     this line after the `is_nil(revoked_at)` filter in `lookup_key/1`:
     `|> Ash.Query.filter(is_nil(expires_at) or expires_at > ^now)` (with `now = DateTime.utc_now()` bound above it).
  4. *Unique CSAT survey-token digest.* Run `mix samen.gen.csat_token_digest_unique`, then `mix ecto.migrate`. Same engine and
     behaviour as step 2, for every `*_csat_survey_token` table in your `:ash_domains` (`--key table:column` names one); it
     also drops the plain `<table>_digest_idx` the unique index makes redundant, and `down` puts it back. A table that
     already has the unique index (a freshly generated app) is skipped.
- **Fixed: every CSAT survey-token digest is unique.** `preview` reads the row by digest with `limit(1)` and `respond` consumes
  every row matching the digest, yet the index was plain: one row per digest rested on 32 random bytes. New apps create a
  unique index in the first migration; the committed hosts (demo `dsc`, driftwood `dcs`/`dco`, pawchart `psc`/`pqo`,
  samen_web `scw`/`wco`) got a `CONCURRENTLY` migration that replaces the plain index.
- **Fixed: `mix samen.gen.api_key_digest_unique` and `mix samen.gen.csat_token_digest_unique` find the tables in a real
  app.** Discovery matched the logical attribute name (`:token_digest`) against `_token_digest`, but only the stored
  column carries the table prefix (`aqt_token_digest`), so with no `--key` it found nothing in any real app and stopped
  with "no ... table found" (it wrote nothing). It now reads the stored column through `Samen.Catalog.fields/1`, and the
  hosts' tests assert discovery finds exactly the tables and columns the shipped migrations name. The CSAT task's
  "no :ecto_repos" error now names itself.

### Fixed: kernel phase D, honest reads (approvals, reveal, delivery lookups, verifier inputs, mailbox, replay)

- **Fixed: a failed approvals read no longer reads as "none", "not found" or "unwired".** `Approvals.existing_pending`
  answered `:none` (so `request/2` went on to write over an unreadable table); `fetch_approval` answered `:not_found`
  for any failure (`get/2`, `cancel/3`, `approve/3`, and the agent's expiry withdrawal all read an outage as "already
  gone"); a configured resource whose repo could not be resolved read as `:no_approvals_module`, which lets
  `Reveal.Grants.approve/2` fall back to its engine-less path. They are now `{:error, :unavailable}` /
  `{:error, :approvals_unavailable}`, reported; only a missing row (or an id that cannot name one) is `:not_found`. The
  agent's execution seam names an unreadable approval `:approval_unavailable`.
- **Fixed: `Reveal.Grants`** reports a parallel `pii_reveal` approval it could not open, a failed pending list, and a
  pending approval dropped from the queue because its request row is gone.
- **Fixed: a reveal request whose engine approval failed to open is recovered, not only reported (S6).** The request now
  persists its org (`rvq_org_id`, nullable; a non-UUID org is stored NULL and reported once as
  `reveal_request_org_uncastable`) and **records its own decision**: `rvq_status` is `approved` / `denied` / `cancelled`,
  written in the same transaction as the decision under a row lock on the request (`Grants.do_approve/4`,
  `Grants.deny/2`, the handler's `on_reject/2` and the new optional `Approvals.Handler.on_cancel/2`, which
  `Approvals.cancel/3` runs). `Grants.approve/2` / `deny/2` refuse a request that is no longer pending
  (`{:error, :not_pending}`): no second approval, no second grant. `pending_for_org_result/2` re-opens, idempotently,
  the missing approval of the org's recent requests that are still `pending` (14 days, at most 200, newest first;
  decided requests do not use the bound) before it lists. The re-open re-checks under the request's row lock that the
  request is still pending and has no approval in any state, so a request decided between the scan and the re-open is
  not revived; the recovered approval keeps the request's own `requested_at`. A failed re-open is reported AND the
  queue answers **`{:partial, rows, n}`** (`RevealApprovalsLive` says "n pending reveal request(s) could not be
  shown"; `pending_for_org/2` raises), and an orphan scan that cannot run makes the queue `{:error, :unavailable}`.
  Sabotages 1010-1013 and 1016-1026.
- **Upgrade (apps generated before this change): run `mix samen.gen.reveal_requests`, then `mix ecto.migrate`.** A
  generated app is a copy that depends on `samen_core` by path: the new `RevealRequest` schema selects `rvq_org_id`, so
  an app on the old table fails every reveal read and write with `undefined_column` until it has the column. The task
  writes two migrations of literal SQL for the app's approvals prefix (`--approvals-prefix`, default read from the
  configured approvals resource; `--no-approvals` for a host with no engine): `rvq_org_id` under `expand_setup/0`, then,
  outside the DDL transaction and in batches, the backfill of `rvq_org_id` (from the request's approval) and
  `rvq_status` (from approvals, grants and recorded denials; a request whose records disagree, or that has none, stays
  `pending` and is counted in the output) and the `(org, inserted_at, id)` index `CONCURRENTLY`. The committed `demo`,
  `driftwood`, `pawchart`, `samen_web` and test-repo migrations (`20261118100000`, `20261118100001`) are its output.
  `Migration.ExpandContract.chunked_backfill/4` gains a `:where` option (a literal predicate replacing the
  `column IS NULL` guard) so a backfill can skip rows it cannot answer for.
- **Changed: `QueryBudget.over_threshold?/2` raises on an unreadable ledger** instead of answering `false` ("under
  budget"). `record/1` and `check/2` keep their documented fail-open posture but report by name instead of inspecting
  the exception.
- **Fixed: a failed send lookup no longer files a bounce or complaint as "no matching receipt".**
  `MarketingReceiptLookup` and `Sequences.ReceiptLookup` answer `{:error, :unavailable}`; `Deliverability.handle_event/2`
  returns `{:error, :receipt_lookup_unavailable}`.
- **Fixed: `NoPlaintextPii.Context`** no longer drops a resource whose table cannot be determined from the sweep, nor
  turns a failed dependency lookup into "no OTel, nothing to assert"; an unreadable non-PII registry (no exemptions) is
  reported.
- **Fixed: mailbox sync no longer anchors a message to nothing for good when the CRM match read fails.** `Match` reads
  raise; `sync/2` aborts with `{:error, {:match_unavailable, :read_failed}}` and leaves the cursor, like an unavailable
  dedupe lookup. A cursor update that fails is reported.
- **Fixed: the replay resolver and sanitizer report** a failed record read, grant/vault prefetch, per-record resolve,
  shred attestation or unwalkable assign (values unchanged: nothing resolves, nothing is claimed shredded).
- **Fixed (test): `KitStatesTest` "host_nav_extra" flaked on another async test's log line.** `ExUnit.CaptureLog` sees
  the whole node; `Samen.WebTest.OwnLog` keeps only the calling process's lines.
- `kernel_swallow` ceilings: rescue 123 -> 91, error arms 19 -> 15. Sabotages 985-1001.

### Fixed: kernel phase C review (verifier evasion, billing ledger gaps, replay unavailable card)

- **Fixed: `agent_coverage` could miss an agent-loop re-entry through a decoy `@attr` value.** One rescue covered every
  value of `@k`, so `@k :lists` placed before `@k Samen.AI.Agent` made `source_reenters_loop?/1` read false. Each value is
  now decided on its own, without a rescue.
- **Fixed: `ai_prompt_masking` crashed on a `defmodule __MODULE__.X` in a tool's source file** (`Module.concat/1` raises
  `FunctionClauseError`, not the `ArgumentError` the narrowed rescue named). The parts are guarded instead.
- **Added: `mix samen.verify.movement_continuity` (`Samen.Billing.MovementContinuity`).** A skipped `mov` row used to
  leave only a failure report; the ledger now has a check: each subscription's rows must chain (`mrr_before_cents` equals
  the previous `mrr_after_cents`, the first starts from 0), the last `mrr_after_cents` must equal the live MRR, and a
  revenue-active subscription must have a row. Report only, ids and cents only, wired for the demo host.
- **Documented, measured: which failures roll the subscription write back.** `SubscriptionMovement` is best-effort only
  for failures that send no SQL (an unresolvable price resource, a classifier refusal, a validation error): the
  subscription write stands and no row is written. A failing SQL statement inside the write's transaction aborts it, so
  the subscription write is rolled back too (`demo/test/movement_continuity_test.exs`).
- **Fixed: `MovementBackfill.from_snapshot/1`** declares `{:error, :unavailable}` in its `@spec`, and one unreadable
  subscription no longer stops the whole run: it is skipped, counted in `failed` and reported; `{:error, :unavailable}`
  is only for a failed read of the snapshot itself.
- **Fixed: the replay player's `:unavailable` arm is now driven through the real load path** (test and sabotage).

### Fixed: an erasure that failed after the key shred is resumable (AI derived context is withdrawn on the retry)

- **Fixed: `Samen.Erasure.shred/2` could report completion while AI runs citing the subject were never withdrawn.** The
  irreversible `Kms.shred/1` runs before the seal transaction, and the pseudonym `subject_ref` the fold-ledger and
  fold-source arms need dies with the key. A failure of any step 2-5 after the shred rolled the transaction back; the
  retry saw `:shredded`, recorded both arms as `:no_pseudonym` and never stamped the fold index. The ref is now committed
  as a `"pending"` marker (in `era_erasure_report`, no schema change) before the shred and deleted by the completing
  transaction; the retry resumes from it and its report equals an uninterrupted run's. A shredded key with no marker and
  no earlier completed report now fails loudly (`{:error, {:shred_reference_lost, report}}` + an `operator_action_required`
  report; `acknowledge_lost_reference: true` is the operator override). `Erasure.pending/1` lists unfinished erasures.
  ADR-048 §7.3 addendum 2026-11-15; `samen_core/test/erasure_resumable_test.exs`.

### Security: vault tokens are bound to the record that holds them (High)

- **Fixed: a tenant could read another subject's PII, across orgs, by planting its vault token.** Tokens are stored
  "token-only downstream" by design, so anyone with read access to a replica, the CDC mirror, a backup, version or audit
  rows could learn one; `VaultField.cast_input/2` accepted any `"vt_"` string as an already-vaulted token, so it could be
  written into a vaulted field through a form, a CSV cell, an automation literal or an inbound mail body, and
  `PiiResolution` revealed it. A plaintext that merely started with `vt_` was also stored unencrypted. Now a raw string is
  always plaintext and is encrypted; only an internal `%Masked{}` means "already vaulted".
- **`Samen.Vault.Change` binds every changed `%Masked{}`** to the record's subject (its primary key), vault and field in one
  query (`Vault.check_bindings/3`); a mismatch is a changeset error naming the field and reason, never the token, and is
  reported (`:vault_token_unbound`). An untouched round-trip of the record's own value costs no query. A create without an
  explicit primary key cannot carry a `%Masked{}`. An upsert-create on a PII resource is refused twice: at build time when
  the action or `for_create(..., upsert?: true)` says so, and AFTER the write for a call-site `Ash.create(cs, upsert?: true)`
  (inside the action every create looks like an upsert): an `after_action` compares the written row's primary key with the
  vault subject and errors on a mismatch, which rolls back the vault rows with the domain write. The same `after_action`
  refuses a later hook that swapped a vault attribute after `Vault.Change` approved it. Atomic writes of a vault field never
  reach the data layer (Ash refuses them; `Vault.Change` has no `atomic/3`).
- **The write guard no longer depends on the caller's transaction options.** It rolls back itself (`repo.rollback/1`), so
  `rollback_on_error?: false` cannot leave a refused write durable; a create/update on a PII resource with NO open
  transaction (an action declared `transaction? false`, a bulk `transaction: false`) is refused before any vault insert or
  row write. The read-side unbound report is capped per reason (20), and what the cap cuts is reported as
  `vault_token_unbound_truncated` with the suppressed count.
- **Removed: `Samen.Vault.materialize/2`** (public, no callers in the tree). Resolve through `Samen.Api.PiiResolution`.
- **Reads reveal bound-only.** `Vault.reveal/3` gains `field:`, checked with `subject_id:` before any key is unwrapped;
  `PiiResolution` asserts the holder's primary key and field for every value, never unwraps a foreign subject's DEK, and
  renders a mismatch masked/absent on every plane. The webhook signing-secret reveal asserts the endpoint's id and field, and
  a mismatch is discarded and reported once (permanent, not retried 20 times). The read-side `:vault_token_unbound` log
  line now names resource, field and record id (never a token or value). `Samen.Reveal.reveal/5` forwards `:field` and
  REQUIRES `:subject_id` (`{:error, :subject_required}`). A legacy `vt_`-prefixed plaintext cell blocks updates of a
  versioned record with an explicit error pointing at the verifier (remediation in docs/guides/gate-failures.md).
- **Behaviour change:** a `"vt_…"` string written to a vault field (including by an operator, formerly a no-op) is now
  plaintext; an operator typing one is refused like any plaintext write. `Vault.token?/1` is the token grammar.
- **New verifier** `mix samen.verify.vault_token_binding` (`Samen.Vault.BindingScan`, ci steps for samen_core, demo,
  driftwood, pawchart, samen_web): finds existing cells that do not belong to their record (`foreign_subject`,
  `field_mismatch`, `dangling_token`, `non_token_value`, `shared_token`). Report only; no token or value in its output.
- Proof: `vault_token_input_test.exs`, `vault_change_integration_test.exs`, `pii_resolution_token_binding_test.exs`,
  `vault_dek_reuse_test.exs`, `verify_vault_token_binding_test.exs`, `csv_masking_test.exs`; sabotages 905-921 and 927-934. ADR-001
  section 6.2, ADR-036 section 12, ADR-041 section 13a.

### Vault: one KMS unwrap per subject per resolve call (ARCH-2)

- **`Samen.Api.PiiResolution` unwraps each subject's DEK once per call, not once per vaulted value.** A page of N rows x M
  vaulted fields over S subjects costs S `Samen.Kms.unwrap/1` calls instead of N x M. `Samen.Vault.unwrap_subjects/1`
  builds a `Samen.Vault.DekMemo` (redacting `Inspect`) from only the rows the plane will decrypt; it lives in the call's
  `opts` and nowhere else, so there is no cross-call reuse and a subject shredded between calls is masked on the next. The
  shred check is the unwrap, so within one call it runs once per subject: a subject shredded mid-call can still be
  served for the rest of that call. `Vault.reveal/3` has no audit or breadth ledger (the audited `Reveal`/`BreakGlass`
  paths never take a memo). A failed unwrap denies only that subject. The memo and `prefetch/4` opts are single-use
  (never stored; a memo from another process is ignored; call sites pinned by `vault_dek_call_site_scan_test.exs`)
  and the new `deks:` option is documented on `reveal/3`. The KMS behaviour is unchanged. A cross-request cache stays out of scope (ADR-001 section 6.1). Proof: `vault_dek_reuse_test.exs`,
  sabotages 887-890.

### Mutation gate: the security core (ARCH-26)

- **The tier-1 watch-list now covers the rest of the security core: 12 -> 23 modules, 166 -> 401 mutants.** Added, by
  guarantee: vault (`Samen.Vault` key-absence scanners, `Samen.Kms.Crypto`), plane-aware masking
  (`Samen.Api.PiiResolution`), org scoping (`Samen.Policy.OrgScope`), operator grants (`Samen.Reveal.Grants`,
  `Samen.Reveal`, `Samen.BreakGlass`), erasure (`Samen.Erasure`) and the audit hash chain (`Samen.AuditChain`,
  `.Writer`, `.Canonical`). Every survivor is closed by a test (new files `vault_key_column_scan_test`,
  `pii_resolution_planes_test`, `pii_resolution_bag_planes_test`, `policy/org_scope_test`, `reveal_grants_windows_test`,
  `erasure_branches_test`, `audit_chain_{canonical,writer,branches}_test`, plus additions to `break_glass_test` and
  `observability/reveal_span_test`) or by a proven-equivalent ledger row (6; `Grants.write_audit/3` now takes atom keys only and raises on any other, so its string-key row is gone, and `verify_anchor` reads head and sealed-seq hash in one statement). Sabotages 870-876 promote the most
  important sole-killer mutants. `Samen.AI.MaskedPayloadScan` moves into test support so `ai/verbs_test.exs` no longer
  needs another test module loaded first, and the `Widget` fixture declares a reveal action so the operator-with-grant
  custom-bag posture is provable.

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
- **AI / agent and automation areas** (`samen/ai/**`, `samen/automation/**`; kernel ceilings rescue 227 -> 176, error-arm 26 -> 20). Fail-open
  sites fixed, each with a red test, a positive control and a sabotage (855-869): a failed `FoldSource` existence probe raises instead of
  reading as an absent index (the erasure withdrawal walk and the per-turn withdrawal check answered "nothing to withdraw");
  `Embeddings` reads an introspection failure as vault-routed (fail closed), its nearest-neighbour and stale reads are
  `{:error, :unavailable}` and `reembed_stale/1` no longer claims `{:ok, 0 re-embedded}` (`stale_rows/3` raises, `stale_rows_result/3` is the
  tagged form); `Agent.reject_proposal/3` rolls back when the turn or run cannot be READ; the agent Health `summary/runs/turns`, the automation
  Health `summary/runs` and `Breaker.kills/1` answer an outage, not an empty fleet or "no kills"; `RunWorker` skips a run (`internal_error`)
  whose subject cannot be READ, because an empty subject passes every `neq` / `not_in` / `is_nil` gate; `DispatchWorker` no longer reads an
  unknown event as `:created`; `ReminderFire` and `EscalationAdvance` fail the change when their reload fails; `MutateRecord.undo/3` reports a
  compensation that did not happen. The fail-closed tool, capability, catalogue and surface probes stay non-fatal and now report by name; the
  four `String.to_existing_atom` rescues collapse into one reviewed `Support.safe_atom/1`. Web LiveViews that map `{:error, _}` to `[]`
  (operator agent / automation health) are the web phase's.
  Review follow-ups (sabotages 877+): `RunWorker.reread_subject/2` skips (`internal_error`) on a resource it cannot resolve or classify instead of
  firing against an empty subject; `ReembedWorker` returns `{:error, :unavailable}` (Oban retries) instead of a `CaseClauseError`;
  `ActionStep.undo/4` returns a failed compensation to Reactor (which stacks an `UndoStepError`, still undoes the remaining steps and fails the
  run) and `RunWorker` stamps it on the Run outcome as status `compensation_failed`; a malformed turn id in `reject_proposal/3` is `:turn_not_found`
  (a garbled approval can still be rejected), only a failed read of a well-formed id is `:unavailable`; the operator agent and automation health
  pages render the kit error state with a retry when a read failed (no longer "No runs recorded."); `Embeddings.embedder_simulated?/1` answers
  `true` (not verified real) when a provider's `simulated?/0` raises; `ScheduleAdvance` enqueues no dispatch when the org cannot be resolved;
  `Failure.report_write/3` reports failed writes as `write` (the lint scanner counts it as a report) and the write sites use it.
  Second review (sabotages 893+): the `enqueue_reminder` and `escalate` compensations no longer answer `:ok` when the undo failed - a row that is gone
  (or an escalation already past its transitions) is `:ok`, any other failed read or write is reported (`reminder_undo` / `escalation_undo`) and
  returns `{:error, :undo_failed}`, so it is on the Run as `compensation_failed`; `Remind.cancel/3` and `Escalate.resolve/3` tell a failed read from
  a missing row; an `UndoStepError` that is not the bounded compensation map no longer overrides the run's `error_kind`; a non-UUID `select_run` on the
  operator agent health page is "no such run", not an outage; the `embedder_simulated?` comments state how they differ from the Chokepoint's.

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
- **The index name carries the sort column** — `<table>_org_<sort>_id_idx` (`<table>_org_id_idx` with no `keyset_sort`) — so a
  changed `keyset_sort` is a different index, not a silently skipped `IF NOT EXISTS`. `mix samen.gen.indexes` and the committed
  retrofit migrations spell table, columns and name as LITERAL `{table, columns, name}` tuples, never resource modules: an
  applied migration cannot change meaning when code later does. Every generator run writes a new file whose module name
  carries its timestamp (a re-run no longer collides). After a shape change `mix samen.verify.indexes` names the old index,
  says to re-run the generator for a migration that builds the new one, and to drop the old one in a follow-up.
- **`mix samen.verify.indexes`** (new; reads the live catalog, fails on anything it cannot inspect, no exemptions) runs as a
  step per app in `ci/steps.conf` (each on a database rebuilt from scratch) and as step 13b of a generated app's `ci.sh`. It also
  rejects an index whose NULLS ordering, collation or operator class is not what the page's ORDER BY needs. A host that mounts a
  domain but not all its tables lists the others in `config :<app>, :index_unmounted` — printed as NOT inspected on every run,
  and a stale entry fails. **`mix samen.gen.indexes`** writes the retrofit migration. `Samen.Migration` gains
  `create_org_keyset_indexes/2` and `create_jsonb_path_index/4` (plus their `drop_` pairs).
- A `CREATE INDEX CONCURRENTLY` that failed leaves an INVALID index that `IF NOT EXISTS` skipped forever; `concurrent_index/3`
  and the concurrent jsonb-path index now drop a same-named invalid index first (a valid one is never touched). Run
  `mix samen.verify.indexes` against production after the migration: it counts only a valid, ready index.
- `Samen.Web.Reads` ANDs a redundant bound onto the keyset cursor (`f <= v` for DESC; `f >= v` for ASC only on a column that
  cannot be NULL) so a deep page seeks in the index instead of filtering from the start of the org's range; the result set is unchanged.
- The ASC cursor bound is decided from the DATABASE column (`pg_attribute.attnotnull`, resolved once per resource and cached in
  `:persistent_term`; unknown means no bound), not from the Ash attribute's `allow_nil?` — the two can disagree after a hand or pending
  migration, and the bound drops the NULL tail. `mix samen.verify.indexes` also reports a sort attribute that says non-nil over a
  nullable column. `drop_invalid_index` takes the table's `SHARE UPDATE EXCLUSIVE` lock before looking, so it waits for another
  session's in-flight concurrent build (also `indisvalid = false`) instead of dropping it; only an abandoned invalid index goes. Sabotages 819-823.
- The retrofit migration builds the replay tables' indexes if missing but its `down` never drops them (`Samen.Replay.Migration` owns them for a fresh database).
- `activities_for_person` / `activities_for_company` filter `get_path(custom, ["crm_refs", …])`; two partial expression
  indexes on the exact expression Ash emits now let Postgres `BitmapOr` it with the `(subject_key, subject_id)` index.
- Fixed on the way: `Samen.AI.Agent.FoldSource` had a table in driftwood but no repo wiring (it defaulted to `SamenCore.TestRepo`);
  `config :samen_core, :samen_ai_agent_fold_source_repo, Driftwood.Repo` added. A host that runs the agent loop needs the same line.
- Tests: `Samen.IndexingTest`, `Samen.Web.TenantIndexPlanTest` (EXPLAIN of the real page query, with a drop-the-index control),
  `Samen.Web.CrmRefsIndexPlanTest`, `Samen.Web.KeysetSortParityTest`, `Samen.Web.ReadsCursorBoundTest`. Recorded in ADR-016 §9. Sabotages 745-762 (745-750 the original six, re-anchored; 751-762 the review fixes).

### Audit partition hardening (ARCH-9)

- **`aud_event_default`**: a DEFAULT partition, so a row outside every month lands there instead of failing the (audit-or-refuse) write.
  The roll-forward moves DEFAULT rows into a month it creates (Postgres refuses otherwise), transactionally, losing none. A landing is
  reported (`Failure` + `[:samen,:audit,:partition,:default_landing]`).
- **Runway**: `PartitionManager.runway/2` per partitioned table; gauges `samen.audit.partition.runway_days` / `.default_rows`; `/readyz`
  gains a non-gating `partitions:` advisory (WARN < 31 days or rows in DEFAULT, CRITICAL <= 0, UNKNOWN when unreadable); `Readiness.report/1`
  replaces the controllers' hand-rolled body; alerts.md §7. The roll-forward job now fails when a month cannot be created.
- **`occurred_at`**: a time more than 300 s ahead is clamped to the write time (claim kept in `detail`); past times are kept. Recorded in ADR-002 §7. Sabotages 763-770.
- Existing tests changed: the T128 baseline in `aud_event_test.exs` now drops the DEFAULT partition first (it proves the mechanism, which the
  default now hides).
- **Review fixes (ARCH-9 round 2).** The DEFAULT-row move no longer holds an exclusive lock across a copy of everything: it stages the month's
  rows and a replacement DEFAULT in standalone tables with no lock, then takes `ACCESS EXCLUSIVE` under `lock_timeout`
  (`:partition_move_lock_timeout_ms`, 5 s) for a top-up, a count taken under the lock, and the detach/ATTACH swap; a lock it cannot get fails the
  move (Oban retries). `/readyz`'s partition advisory is cached 60 s per node, bounded by a 500 ms deadline and a 300 ms `lock_timeout`, and is
  UNKNOWN (never a stale `:ok`) when a refresh fails; no partitioned table is UNKNOWN, an unreadable table is named, and only time-partitioned
  tables are read. The default-landing test compares `occurred_at` with in-memory partition bounds (no query per write; the re-read is a
  SAVEPOINT, so it cannot abort the caller's transaction). `AuditEvent.insert/2` clamps a future `occurred_at` too. The host migration `down`
  raises while the DEFAULT partition holds rows. Existing tests changed: rows meant to land in DEFAULT use past dates (1995-1999) because
  `insert/2` now clamps future ones; the fake repos in `readiness_test.exs` gained `transaction/2`. Sabotages 764, 768, 769 re-built for the
  moved clamp and landing test, 771-788 added.
- **Review fixes (ARCH-9 round 3).** The DEFAULT-row move keeps the month's CHECK through the ATTACH (it used to drop it first, so Postgres scanned the
  whole month under `ACCESS EXCLUSIVE`) and gives the replacement DEFAULT its own CHECK so that re-ATTACH is scan-free too; the two `count(*)`
  statements under the lock are gone; the window has a TOTAL budget (`:partition_move_window_budget_ms`, replaces the per-statement
  `:partition_move_statement_timeout_ms`) and an automated move refuses a DEFAULT over `:partition_move_max_default_rows` (500 000). The daily
  `CREATE … PARTITION OF` runs under `lock_timeout` + the budget. The bounds read uses a savepoint only inside a transaction (outside one a
  DEFAULT landing was never classified). `/readyz` emits `runway_unknown` when its refresh misses its deadline. The migration `up` has a
  `lock_timeout`; its `down` guard locks the PARENT `aud_event` (a writer's lock order; locking the partition first deadlocked with a write and aborted the writer) under a `lock_timeout` in every host's `down`. Existing tests changed: the `:force` detach test is back on
  2099 with a without-force refusal as its control; `FaultRepo`/`CountingRepo`/`ToggleRepo` delegate `in_transaction?/0`; the February-bounds test
  asserts the row's partition. A creator that loses the race for a month (`duplicate_table`) is a success once the existing relation is verified to be that month's partition with those bounds; an unreadable (MINVALUE/MAXVALUE) sibling bound falls back to the scanning ATTACH instead of failing the move; a zero or non-integer `:partition_move_lock_timeout_ms` / a zero budget on a plain create is refused (never Postgres's "no limit"); `:partition_move_clock` (a 0-arity ms function) lets a test consume part of the window budget without sleeping. The runbook's "DEFAULT too large to move" remedy raises both knobs. Existing tests changed: the total-budget test now consumes a known part of the budget after the DETACH and asserts every later statement's timeout is at most what is left; the budget-0 test restores its config on failure. Sabotages 824-838, 847-854.

### One instance per database (ARCH-3, ADR-054)

- **ADR-054** declares and inventories it: 14 node-local mechanisms (replay-nonce cache, AI kill switch, rate limiter, flag cache, FileBacked
  KMS, local audit/anchor/files, PubSub/Presence, ...) with what two instances do to each, what IS safe to scale (Postgres, Oban), the revisit
  triggers and a path to cluster safety per mechanism. The generated `fly.toml` pins one machine and says why; the deploy runbook, launch
  checklist and getting-started say it; the "multi-node" compliance row is qualified to the job substrate.
- **`Samen.SingleNode`** (wired through `Samen.Observability.child_specs/2`, so no host code): armed only for a SERVING instance (the
  endpoint binds a listener). `Peers` refuses to boot with `libcluster`/`dns_cluster` configured or a visible node connected, and disconnects
  a visible peer at runtime, loudly; hidden nodes (`bin/app remote`, `rpc`, `iex --hidden --remsh`) are allowed. `Lease` holds a shared
  session advisory lock on a dedicated connection and counts the other holders: a second instance on the same database is reported in
  `/readyz` as `single_node: CRITICAL` after a 5-minute grace period (a rolling deploy overlaps on purpose), `strict: true` makes the late
  instance answer 503, an unreadable state is `UNKNOWN` (never single; PgBouncer transaction mode is latched as `connection_pooler` once a statement lands elsewhere, fix
  with `lease_url`). Metrics `samen.single_node.*`; alerts.md §8. Sabotages 789-818 and 839-846.
- Existing tests changed: none (the `single_node:` advisory line exists only where a lease runs).

### Host action required (existing hosts and generated apps)

0. **Run the migration `20261114120000_aud_event_default_partition`** (ARCH-9; copy the reference in `driftwood/priv/repo/migrations/`; a
   generated app made after this change has it in its `aud_event` migration). Replace a hand-written `readyz` with
   `Samen.Web.Readiness.report(repo: MyApp.Repo)`.

A generated app is a copy, so these do **not** reach an app generated before the change. Re-generate into a scratch
directory and diff, or apply by hand:

1. **Copy new migrations** (fixed timestamps; each file is the reference in `driftwood/priv/repo/migrations/` or the
   `samen_core/priv/templates/m_*.eex` template), then re-dump `schema.dict.json` with `mix samen.catalog.dump`:
   `20260925100000` rollup `subject_id` becomes text (host-named, e.g. driftwood's `…_driver_load_rollup_subject_id_text.exs`) ·
   `20260925110000` usage-event ledger · `20260926100000` usage tally `reported_quantity` ·
   `20261005100000` entitlement usage limit · `20261006100000` agent cached-input bucket (hosts running the agent loop) ·
   `20261009100000` `samen_replay` (also register `Samen.Replay.Domain` in the host's domain registry: `config :samen_core, :host_domains` and the host app's own `config :my_app, ash_domains`) ·
   `20261114100000` the tenant keyset indexes (**ARCH-4** — run `mix samen.gen.indexes` in the host; it writes a
   `CREATE INDEX CONCURRENTLY` migration of literal `{table, columns, name}` tuples over every org-scoped resource, safe on populated tables, no write lock; copy the
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
8. **One instance per database (ADR-054).** Hosts that call `Samen.Observability.child_specs/2` get the guard for free. Generated apps
   made before this change: run ONE machine (`fly deploy --ha=false`, `fly scale count 1`; copy the comment and `strategy = "rolling"` from
   `samen_core/priv/templates/fly_toml.eex`), remove `dns_cluster`/`libcluster` if present (the app now refuses to boot with them), and
   use `Samen.Web.Readiness.report/1` for `/readyz` so the `single_node:` line appears. Behind PgBouncer in transaction mode set
   `config :samen_core, Samen.SingleNode, lease_url: <direct URL>`.
9. **Seed tasks** should boot through `Samen.SeedBoot.start!/2` instead of `@requirements ["app.start"]`, or
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
- **A self-test can no longer write to the repo it tests.** `scripts/ci_test.sh` built its fixture repos with `cd "$R" && git init …; …; git add -A && git commit … && git update-ref refs/remotes/origin/main HEAD`, chained only on the first line: when `$R` could not be entered the rest ran in the caller's directory, committed onto a developer's branch and moved the real `origin/main` (so every diff-aware gate selected nothing). New `scripts/fixture_guard.sh`, sourced by `ci_test.sh` and the sabotage-tooling, lanes, apply-check and double-sweep self-tests: no usable temp root exits before anything runs; `git` is shadowed and refuses (rc 97) any command whose repository is not inside the physical temp root; the fixture builder is `set -e` with a fatal `cd`; on exit the real repo's HEAD, branch, `origin/main` and staged index are compared with their start state (not the working tree, which neighbouring steps and Python's bytecode cache legitimately write) (`SELF-TEST ESCAPED INTO THE REAL REPO`, never auto-repaired). `sabotage reanchor`'s scratch repo checks its `git init` and toplevel. New case `ESCAPE` (sabotages 891-892).

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
