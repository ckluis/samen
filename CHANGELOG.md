# Changelog

All notable changes to Samen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); Samen aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from 1.0 onward.

## [Unreleased]

> **Catch-up, 2026-11-13.** This file had not been touched since 2026-09-21 (`72717d25`); the entries below,
> through "Generators, docs and agent experience", are reconstructed from `git log 72717d25..HEAD` and grouped by theme.
> There is no version or tag for them: nothing here has been released, and no number is invented. The detailed
> older entries follow unchanged under "Added" and onward.

### Security: identity authorization, round 3

- **Fixed: an admin could demote, suspend or re-role an owner or a peer admin.** `Samen.Policy.ManageRole` judged only the
  role a membership write was SETTING, so `%{role: :member}` (or `status: "suspended"` together with a lower role)
  passed for an admin against an owner's or another admin's row. A write on an existing membership (update, destroy) must
  now out-rank BOTH the role the row holds in the database and the role being set. The stored role is read by primary key
  on the write repo, never from the record in hand (which may be stale or carry `%Ash.NotLoaded{}` for `role`); a row it
  cannot read refuses the write. `Samen.Scope.Role.may_manage?/2` is strict, so an owner cannot demote, suspend or remove
  another owner either, and no write through `ManageRole` can leave an org without an owner. A caller that relied on an admin
  editing an owner's or a peer admin's membership now needs an owner (for an admin) or no longer can (for an owner).
  Sabotages 1322 and 1323.
- **Fixed: a suspended member kept their role and their org in an existing signed-in session.** A membership whose
  `status` is not `"active"` (suspended, invited) now confers no role and no org access, the rule an API key's acting role
  and the settings role lookup already applied. `Samen.Auth.OrgActor` is the one resolver: `active_membership/3` (the
  lowest-ranked ACTIVE membership of a user in an org, `:none` otherwise) decides `resolve/3` and `resolve_result/3` (the
  session actor's role), `authorized_org_ids/2` and `authorized_org_ids_result/2` (the orgs a session may act in, so the org
  switcher and `?org=` no longer reach an org the member is suspended in), and `Samen.AI.Agent.Approver` (a suspended
  member can no longer approve an agent action). `PawChart.Auth.authorized_org_ids/1` filters on `status == "active"`.
  A suspended user whose only org is the suspended one resolves no org, the same answer as a credential with no
  membership. `Samen.Policy.ManageUser` still ranks a suspended target by its role, on purpose: an admin cannot suspend
  an admin to get around the rank rule. **Upgrade notes:** `authorized_org_ids/2` now needs an active membership as well
  as a `User` row in the org; a host seam that lists orgs from its own membership table must filter on
  `status == "active"` too.
  An already-mounted LiveView keeps the org set it mounted with until it remounts.
  `ManageRole` returns an error tuple (not `{:ok, false}`) when it cannot read the stored role. Sabotages 1324 to 1327.
- **Fixed: the session cap evicted a live session because of an abandoned expired one.** `Samen.Auth.SessionCreate`
  counted every unrevoked session toward `Org.max_concurrent_sessions`, expired ones included, so with a cap of 2 an old
  session still in use plus a newer expired one made the next sign-in revoke the in-use session. Only sessions that can still
  resolve (unrevoked and not past `expires_at`) count toward the cap now. **Upgrade notes:** none; a credential that sat at its
  cap with expired sessions now keeps its live ones. Sabotage 1328.

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

### Security: identity authorization, round 3 (second read-only review of round 2)

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
   `20261009100000` `samen_replay` (also register `Samen.Replay.Domain` in **both** `:ash_domains` lists) ·
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
9. **One instance per database (ADR-054).** Hosts that call `Samen.Observability.child_specs/2` get the guard for free. Generated apps
   made before this change: run ONE machine (`fly deploy --ha=false`, `fly scale count 1`; copy the comment and `strategy = "rolling"` from
   `samen_core/priv/templates/fly_toml.eex`), remove `dns_cluster`/`libcluster` if present (the app now refuses to boot with them), and
   use `Samen.Web.Readiness.report/1` for `/readyz` so the `single_node:` line appears. Behind PgBouncer in transaction mode set
   `config :samen_core, Samen.SingleNode, lease_url: <direct URL>`.
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
