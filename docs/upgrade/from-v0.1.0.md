# Upgrading from v0.1.0

This guide takes an app built on samen `v0.1.0` to the current tree. It consolidates every upgrade note in `CHANGELOG.md`
since that tag, plus what an upgrade of a generated app showed in practice (the last section says what was run), in the order
you should do the work. Read [README.md](README.md) first for how upgrading works today. To hand the work to an AI coding
agent, give it the prompt in [prompts/from-v0.1.0.md](prompts/from-v0.1.0.md); it tells the agent to read this guide in full.

How to use it.

- Each step says what to change, how to find the code, why, and what you see if you skip it. The CHANGELOG heading a step came
  from is in parentheses at the end. "Observed in the upgrade test" means the step comes from running the upgrade, not from a
  CHANGELOG entry.
- An app made by `mix samen.gen.app` is a copy of the templates. A template fix reaches your app only if you apply it by hand
  or compare with a freshly generated app (step A5).
- Not every step applies to every app. Skip a step whose scope or code your app does not have, and write down that you skipped it.
- Do the groups in order: A before you start, B config and what stops the app compiling, C migrations, D code, E tests,
  F data checks on production, G verify. The generators in C compile your app, so finish B first.
- `<app>` is your OTP app name, `<App>` its module. Table and column names below use the prefixes of a generated app; yours
  are in `lib/<app>/operator.ex`, `lib/<app>/billing.ex` and `schema.dict.json`.

## A. Before you start

### A1. Start from a clean, green tree

Create a branch and commit everything. Run your tests and your gate. For a generated app the gate is
`MIX_ENV=test bash ci.sh` and it ends with `<app> CI gate: ALL PASSED`. Write down: the number of tests passed, the number of
files in `priv/repo/migrations`, and the databases you will migrate.

Why: when something fails later you need to know it was green before. If skipped: you cannot tell an upgrade failure from an
old one. (Observed in the upgrade test.)

### A2. Check the toolchain and dependency pins

Elixir `>= 1.20.4` and OTP `29.1.1`. In `mix.exs` set `elixir: ">= 1.20.4"` and Bandit `{:bandit, "~> 1.14"}`. The current
pins are Ash `3.37.2`, AshPostgres `2.15.2` and AshOban `0.10.2` (exact); samen's own `mix.exs` files declare them, so a
path dependency brings them.

Find it: `rg -n 'elixir:|:ash\b|ash_postgres|ash_oban|bandit' mix.exs`

Why: a lower toolchain does not compile the framework. If skipped: `mix deps.get` or the compile of `samen_core` fails on the
version requirement. (CHANGELOG: "Host action required (existing hosts and generated apps)", item 6)

### A3. Point your samen dependency at the new tree

A generated app depends on samen by path (`{:samen_core, path: "../samen_core"}` and `{:samen_web, path: "../samen_web"}`).
Update the checkout those paths point at to the tree you are upgrading to, or change the paths, then run `mix deps.get`.

Find it: `rg -n 'samen_core|samen_web' mix.exs`

Why: this is the upgrade; nothing else changes the framework code your app runs. If skipped: you are still on the old framework
and no later step applies. (Observed in the upgrade test: `mix deps.get` alone moved the pins; no `mix deps.update` was needed.)

### A4. Carry your abbrevs into the new tree's registry

Your app's abbrevs were reserved in the `samen_core/priv/abbrev_registry.json` of the checkout you generated with. The new tree
has its own registry. Reserve every row of your app in it with the allocator, never by editing the file:

    jq -r '.hosts["<app>"] | to_entries[] | "\(.key) \(.value)"' <old samen tree>/samen_core/priv/abbrev_registry.json |
      while read abbrev owner; do
        (cd <new samen tree>/samen_core && mix samen.abbrev.reserve --host <app> --abbrev "$abbrev" --owner "$owner")
      done

The allocator is idempotent: a row already present is a no-op, so this is safe when the new tree is your old checkout updated in
place. Commit the registry change with your app.

Find it: `rg -n 'abbrev' lib | head`

Why: every resource checks its abbrev against the registry at compile time. If skipped: compile fails with
`abbrev "<abc>" for <Module> is not in the abbrev registry`. (Observed in the upgrade test.)

### A5. Generate a reference app in a scratch directory

From the new samen tree, generate an app with the same module, prefix, abbrev and flags as yours into a scratch directory,
without reserving abbrevs and without compiling:

    cd <new samen tree>/samen_core
    mix samen.gen.app --module <App> --prefix <pp> --abbrev <abc> --web --api --no-reserve-abbrevs --no-compile --target <scratch dir>

Keep it. Later steps say "compare with the reference app": `diff -r` it against your app, ignoring `_build`, `deps` and
`priv/dev_keystore`. `--no-compile` is needed: without it the generator compiles the new app, and the compile fails because
its abbrevs are not reserved.

Why: the CHANGELOG says a template fix reaches an older app only if you re-generate and diff or apply it by hand. If skipped:
you find every template change by reading the CHANGELOG alone. (CHANGELOG: "Host action required (existing hosts and generated
apps)"; observed in the upgrade test for the flags.)

## B. Config, and what stops the app compiling

### B1. Rename `:ash_domains` to `:host_domains` for `:samen_core`

In `config/config.exs` change `config :samen_core, :ash_domains, [...]` to `config :samen_core, :host_domains, [...]`. Leave your
own `config :<app>, ash_domains: [...]` alone.

Find it: `rg -n 'config :samen_core, :ash_domains' config`

Why: samen reused Ash's own key for `:samen_core`, so builds printed `is not a Spark DSL module` warnings. All samen readers now
use `Samen.HostDomains.registry/0`. The old key is still read when `:host_domains` is not set, with a deprecation warning. If
skipped: that warning, and the `Spark DSL module` warnings on every build. `mix samen.gen.app` and `mix samen.gen.scope` write
and edit the new key.
(CHANGELOG: "Fixed: flakes and guards round 5 (review of the flakes round, 2026-11-25; includes the `:host_domains` rename)")

### B2. Set Ash's string length counting

Add `config :ash, default_string_length_count: :codepoints` to `config/config.exs`.

Find it: `rg -n 'default_string_length_count' config`

Why: Ash now needs to know how to count string length for `min_length` and `max_length`. `:codepoints` is how SQL counts and is the
value the new template sets. If skipped: compile fails with `` `config :ash, :default_string_length_count` is not set `` on the first
resource that has a string constraint. (Observed in the upgrade test.)

### B3. Add the new resources' abbrevs to your mounts

Each scope mount lists its resources' abbrevs in its `abbrevs:` map. The scopes gained resources after v0.1.0. Compare
`lib/<app>/billing.ex` and `lib/<app>/operator.ex` (and any other mount) with the reference app and add the missing entries. For
a generated app these are: Billing `usage_event`; Operator identity `credential`, `auth_token`, `session`, `user_identity`,
`login_failure`; Operator billing `usage_event`; Operator support `csat_survey_token`. Reserve each new abbrev with the command
the compile error prints, `mix samen.abbrev.reserve --host <app> --abbrev <abc> --owner <Module>` (run in the new tree's
`samen_core`).

Find it: `rg -n 'abbrevs: %\{' -A 14 lib`

Why: without an entry the scope uses its default abbrev, which another host already owns. If skipped: compile fails with
`abbrev "crd" is registered to Demo.Identity.Credential, not <App>.Operator.Credential`, or `... is not in the abbrev registry`
once you have chosen one. (Observed in the upgrade test.)

### B4. Reveal actions must have the probe shape

A `reveal` action declared in `pii do` must be exactly `run({Samen.Reveal.GrantProbe, label: :field})`, take only the argument
`subject_id`, and have the single check `authorize_if(actor_present())` in its policy. Delete the `actor_id` argument and the
hand-written `run(fn ...)`. For a generated app the resource is `lib/<app>/vertical.ex`; the reference app has the finished text.
Drop `actor_id:` from every call to a reveal action and run it as the actor that is asking. `Samen.Reveal.reveal/5` requires
`:subject_id`. The Mailbox `reveal_connection` and `reveal_mail_message` lost their `actor_id` argument too.

Find it: `rg -n 'reveal|actor_id' lib test`

Why: the old probes trusted an identity the caller named, so any code could ask about anyone's grants. If skipped: the resource
does not compile (`reveal action violates the probe rule: ... takes the identity argument :actor_id`), or a call raises an
unknown-argument error or `{:error, :subject_required}`.
(CHANGELOG: "Fixed: authorization and honesty round 5 (evaluation 2026-11-24; tenant roles, authorization and honest reads)",
the entry "Fixed: every generic `reveal_*` probe action trusted a caller-supplied identity and answered anyone"; observed in the
upgrade test)

### B5. Replay (optional)

If you adopt session replay (the `samen_replay` migration in C3), add `Samen.Replay.Domain` to both
`config :samen_core, :host_domains` and your own `config :<app>, ash_domains`, and set
`config :samen_core, :samen_replay_repo, <App>.Repo`.

Find it: `rg -n 'Replay' config lib`

Why: the CHANGELOG asks for the domain in both registries. If skipped: the replay tables are not in the catalog.
(CHANGELOG: "Host action required (existing hosts and generated apps)", item 1)

### B6. Hosts that run the AI agent loop

Add `config :samen_core, :samen_ai_agent_fold_source_repo, <App>.Repo`. Also do D12 (the membership seam).

Find it: `rg -n 'Samen.AI.Agent|gen.agent' lib config`

Why: `Samen.AI.Agent.FoldSource` has no repo wiring of its own. If skipped: it defaults to a test repo module.
(CHANGELOG: "Tenant indexes (ARCH-4)")

### B7. Oban: install the default queues and cron

In `application.ex` start Oban with `{Oban, Samen.Jobs.install_defaults(Application.fetch_env!(:samen_core, Oban))}` and delete
the hand-listed `queues:` from `config :samen_core, Oban` in `config/config.exs`. If you build the Oban config another way and do
not call `Samen.Jobs.install_defaults/1`, add `{Samen.Jobs.BootRun, workers: Samen.Jobs.default_boot_workers()}` to your
supervision tree instead.

Find it: `rg -n 'Oban|install_defaults|BootRun' lib config`

Why: the audit partition rolls forward at boot; a fresh deploy cannot write audit events from its first request without it. If
skipped: audit writes fail once the last partition month ends.
(CHANGELOG: "Host action required (existing hosts and generated apps)", item 7)

### B8. Deployed apps: verify the database certificate

In `config/runtime.exs` replace `ssl: [verify: :verify_none]` with
`ssl: Samen.Deploy.db_ssl_opts([{"DATABASE_URL", database_url}, {"DATABASE_DIRECT_URL", direct_url}])` and move
`direct_url = System.get_env("DATABASE_DIRECT_URL")` above the `config ... Repo` call. Set `DATABASE_SSL_CACERTFILE` to a CA file
for a private CA, or `DATABASE_SSL_VERIFY=none` to keep the old behaviour knowingly (it warns on every boot).

Find it: `rg -n 'verify_none|DATABASE_DIRECT_URL' config`

Why: the app now checks the server certificate. If skipped: nothing changes and the app keeps accepting any certificate. Any other
value of `DATABASE_SSL_VERIFY`, a URL `ssl=` other than `true`, or `sslmode=disable|allow|prefer` refuses to boot and names the
variable. An app generated without `--deploy` has no `runtime.exs`; skip this step.
(CHANGELOG: "Fixed: hardening batch 3 (database TLS, API-key digest uniqueness, expired API keys)")

### B9. `config/prod.exs`, the session cookie and the logger filter

- Create `config/prod.exs` if you have none (the config ends with `import_config "#{config_env()}.exs"`). Put
  `config :logger, level: :info` and `config :<app>, secure_session_cookie: true` in it.
- In the endpoint's `@session_options` add `secure: Application.compile_env(:<app>, :secure_session_cookie, false)`.
- In `config/config.exs` add a keep-list for logged params:
  `config :phoenix, :filter_parameters, {:keep, ~w(id org org_id page per_page limit cursor after before sort sort_by order dir)}`
  and `config :opentelemetry, traces_exporter: :none`.

Find it: `rg -n 'session_options|same_site|filter_parameters|prod.exs' lib config`

Why: the cookie holds the session token. The verifier `no_plaintext_pii` reads the production config and fails closed. If
skipped: the cookie is sent over plain http too, and gate step 6 (`samen.verify.no_plaintext_pii`) fails with
`[logger] prod config — could not read the host's prod config ... config/prod.exs: no such file`.
(CHANGELOG: "Host action required (existing hosts and generated apps)", item 2; "Observability, replay and usage metering"; observed in the upgrade test)

### B10. One instance per database

Run one application instance per database. Remove `dns_cluster` and `libcluster` from your config and supervision tree. On Fly:
`fly deploy --ha=false` and `fly scale count 1`. Behind PgBouncer in transaction mode set
`config :samen_core, Samen.SingleNode, lease_url: <direct URL>`.

Find it: `rg -n 'dns_cluster|libcluster|DNSCluster' lib config mix.exs`

Why: ADR-054. If skipped: the app refuses to boot with `libcluster` or `dns_cluster` configured, or with a visible node
connected, and a second instance on one database is reported as `single_node: CRITICAL` in `/readyz` after a five-minute grace
period.
(CHANGELOG: "One instance per database (ARCH-3, ADR-054)"; "Host action required (existing hosts and generated apps)", item 8)

### B11. Optional settings

- `config :samen_web, Samen.Web.Csv, max_export_rows: n` sets the CSV export limit (default 100,000; a larger export is refused
  with 413 before any row is read).
- `config :samen_core, :secret_vaults, [...]` lists a host vault that holds authentication secrets, so a data-subject export
  never decrypts it.

Find it: `rg -n 'vault' config lib | rg -i 'secret'`

(CHANGELOG: "Fixed: authorization and honesty round 5 ..."; "Security: authorization and erasure, round 4")

## C. Generators and migrations

Take a backup of the database first; the CHANGELOG names point-in-time recovery as the production control for the data
migrations. Do C1 to C7 in your development database and read what each prints, then plan the production run with part F.

Ecto runs migrations in version order and refuses two files with one version. The files you copy keep their reference
versions (all `<= 20261114120000`). Give every generator below its own `--timestamp`, later than your newest migration and at
least ten seconds apart (a generator that writes two files uses `ts` and `ts+1`). The examples use `20261201100000`,
`20261201100010`, and so on.

### C1. Find the schema gap

The scopes you mount gained tables and columns after v0.1.0. With your app compiling (B done), compare the new resources with
your database:

    mix samen.catalog.dump --output /tmp/new.json
    jq -r '.tables[] | .table_name as $t | .fields[] | "\($t)|\(.column_name)"' /tmp/new.json | sort > /tmp/want.txt
    psql -At -F'|' "$DATABASE_URL" -c "select table_name, column_name from information_schema.columns where table_schema='public'" | sort > /tmp/have.txt
    comm -23 /tmp/want.txt /tmp/have.txt        # in a resource, not in the database: needs a migration
    comm -13 /tmp/want.txt /tmp/have.txt | awk -F'|' 'NR==FNR{t[$1];next} $1 in t' <(cut -d'|' -f1 /tmp/want.txt | sort -u) -
                                                # in the database, no longer in a resource: a column that left

A table that is in a resource and missing from the database shows as every one of its columns. Keep the output; C2 works through it.

Why: the CHANGELOG names some of these migrations (C3); this finds the rest. If skipped: reads and writes fail with
`undefined_column` or `undefined_table`, and a column that left a resource fails gate step 2 (`catalog_parity`) with `uncatalogued column`. (Observed in the upgrade test: a generated app
with Billing, Primitives and the operator Identity, Billing and Support mounts was missing 8 tables and 56 columns.)

### C2. Write the migrations for the gap

Reference migrations for every scope are in `driftwood/priv/repo/migrations/` in the samen tree. They are written for driftwood's abbrevs and some contain driftwood-only blocks. For each
gap in the C1 output:

1. Find the reference migration that adds it (the table below lists the ones a generated app with the mounts above needed).
2. Copy it into `priv/repo/migrations/` keeping its version, replace driftwood's abbrevs with yours (the scope's `abbrevs:` map in
   `lib/driftwood/*.ex` against yours, resource by resource), `Driftwood.` with `<App>.`, and delete blocks for tables you do
   not have (the CRM `Opportunity` block of the money migration, for example).
3. Skip a migration for a scope you do not mount.

| Reference migration (version and name) | What it adds | Needed when |
|---|---|---|
| `20260720010000_add_api_key_expiry_fields` | key `expires_at`, `last_used_at` | an API-key table |
| `20260721020000_install_ash_money_extension` | the `money_with_currency` type | any money column |
| `20260721030000_h1_money_migration` | Price `unit_amount` (replaces cents and currency; data copy) | Billing Price |
| `20260721040000_mount_identity_credential_auth_token` | `credential`, `auth_token`, user `credential_id` | Identity |
| `20260721050000_mount_identity_session` | `session` | Identity |
| `20260721060000_add_org_max_concurrent_sessions` | org `max_concurrent_sessions` | Identity |
| `20260721070000_harden_identity_invitation` | invitation expiry, digest, bidx columns | Identity |
| `20260721080000_mount_identity_user_identity` | `user_identity` | Identity |
| `20260722010000_add_credential_totp_fields` | credential TOTP columns | Identity |
| `20260722020000_add_org_onboarded_at` | org `onboarded_at` | Identity |
| `20260722030000_widen_session_inserted_at_usec` | session timestamp precision | Identity |
| `20260722120000_add_invoice_tax_and_hosted_links` | invoice tax and hosted links | Billing Invoice |
| `20260723091000_notification_preference_digest_cadence` | notification preference digest columns | Primitives |
| `20260729210000_billing_plan_price_archivable` | `archived_at` on Plan and Price | Billing |
| `20260729250000_primitives_scope_archivable` | `archived_at` on File, Webhook, FeatureFlag | Primitives |
| `20260729280000_support_scope_operator_archivable` | `archived_at` on Support tables | Support |
| `20260729310000_mount_identity_login_failure` | `login_failure` | Identity |
| `20260807040100_add_operator_csat_survey_token` | `csat_survey_token` | operator Support |
| `20260925110000_add_usage_event_ledger` | `usage_event` | Billing |
| `20260926100000_usage_tally_reported_quantity` | `reported_quantity` on Usage | Billing |
| `20261005100000_entitlement_usage_limit` | entitlement `metric`, `limit` | Billing |
| `20261114120000_aud_event_default_partition` | `aud_event` DEFAULT partition | always |
| `20260925100000_driver_load_rollup_subject_id_text` | rollup `subject_id` becomes text | you have rollups |
| `20261006100000_ai_agent_cached_input_bucket` | agent cached-input bucket | you run the agent loop |
| `20261009100000_samen_replay` | replay tables (see B5) | you adopt replay |
| `20261114110000_work_task_crm_ref_indexes` | Work `Task` `crm_refs` expression indexes | you mount Work |

Two kinds of gap have no incremental migration to copy; write the migration yourself.

- Renamed columns. The Billing provider columns changed from `<abbrev>_stripe_<thing>_id` to `<abbrev>_provider_<thing>_ref`
  (customer, plan, price, subscription, invoice; `stripe_payment_intent_id` became `provider_payment_ref`), on every Billing mount
  including the operator one. Use `ALTER TABLE ... RENAME COLUMN`, one pair per table, with a `down` that reverses it.
- A column that left a resource. Ticket `tags` moved to the Tags scope. If you have tagged tickets, mount the Tags scope and
  copy `20260729120000_add_tags_scope` and `20260729140000_migrate_operator_ticket_tags_to_tag_scope` (and the tenant twin
  `20260729130000_migrate_ticket_tags_to_tag_scope` if you mount tenant Support) so the tags are copied. If the column holds no
  tags, drop it and its catalog row (`DELETE FROM fld_field WHERE fld_table_name = '<t>' AND fld_column_name = '<c>'`). Count the
  tagged tickets first and ask before dropping any data.

Also copy the other CHANGELOG-named migrations for scopes you mount that C1 did not show (it only sees missing columns, not
changed column types).

Why: the framework resources read these shapes. If skipped: the errors in C1. (CHANGELOG: "Host action required (existing hosts and
generated apps)", items 0 and 1; "Changed" with "BREAKING (pre-1.0): CRM Opportunity + Billing Price money columns"; "Removed" with
"BREAKING (pre-1.0): the CRM `Activity` resource is removed" and "the CMS `ContentVersion` resource is retired"; observed in the
upgrade test for the rest.)

### C3. Breaking data changes: money, CRM Activity, CMS versions

Read this before you run the migrations from C2.

- `Opportunity.value` and `Price.unit_amount` are one `money_with_currency` column, replacing the integer-cents and currency pair.
  The migration copies the data and drops the old columns in one step. Reference: `20260721020000` and `20260721030000`.
- The CRM `Activity` resource is removed; its rows are copied into the Work `Task` table and its table dropped. Reference:
  `20260727170000_add_work_scope` then `20260728120000_migrate_activity_to_task`. There is no `down`; point-in-time recovery is the
  control.
- The CMS `ContentVersion` resource is retired. CMS `Page`, `Post` and `Block` are `versioned: :snapshot`; read history from
  `<Resource>.Version`. The old ledger held development data only.

(CHANGELOG: "Changed" with "BREAKING (pre-1.0): CRM Opportunity + Billing Price money columns"; "Removed" with "BREAKING (pre-1.0):
the CRM `Activity` resource is removed" and "the CMS `ContentVersion` resource is retired")

### C4. Reveal requests

    mix samen.gen.reveal_requests --no-approvals --timestamp 20261201100000

An app generated at v0.1.0 has no approvals engine, so pass `--no-approvals`; if your host configures
`config :samen_core, Samen.Approvals, approval_resource: ...` leave the flag off (or pass `--approvals-prefix <abbrev>`). It
writes two migrations: the `rvq_org_id` column, then a batched backfill and an index built `CONCURRENTLY`. A request whose state
cannot be derived stays `pending` and is counted in the migration output.

Why: the new `Samen.Reveal.RevealRequest` schema selects `rvq_org_id`. If skipped: every reveal read and write fails with
`undefined_column`. Without the flag and without an engine the task stops with
`no approvals engine configured; pass --approvals-prefix <abbrev> or --no-approvals`.
(CHANGELOG: "Fixed: kernel phase D, honest reads (approvals, reveal, delivery lookups, verifier inputs, mailbox, replay)")

### C5. Tenant keyset indexes

    mix samen.gen.indexes --timestamp 20261201100010

It writes one `CREATE INDEX CONCURRENTLY` migration of literal `{table, columns, name}` tuples over every org-scoped resource. On
large tables run it in a quiet window: each index builds without blocking writes but reads the table once. Add
`mix samen.verify.indexes` to your gate (step 13b of the reference `ci.sh`).

Why: org-scoped pages are keyset pages that need an index led by `org_id`. If skipped: `mix samen.verify.indexes` fails naming
the missing index. (CHANGELOG: "Tenant indexes (ARCH-4)")

### C6. Unique token digests

Run F4 first, then:

    mix samen.gen.api_key_digest_unique --timestamp 20261201100020
    mix samen.gen.csat_token_digest_unique --timestamp 20261201100030

Run the second after the CSAT table exists (C2). If a table holds a duplicate digest the migration raises, names the table and
column, and deletes nothing; fix the duplicates and run it again. A task that finds no table writes nothing.

Why: the key lookup assumes one row per digest. If skipped: a duplicate digest makes the lookup error (a 503). If the CSAT
migration runs before its table exists it fails with `relation "<abbrev>_csat_survey_token" does not exist`.
(CHANGELOG: "Fixed: hardening batch 3 (database TLS, API-key digest uniqueness, expired API keys)"; observed in the upgrade test)

### C7. API-key scopes

    mix samen.gen.api_key_scopes --timestamp 20261201100040

It writes a data migration that gives each existing key with empty scopes the authority its minter role already allowed:
`{"all": ["read", "write"]}` for owner, admin and member, `{"all": ["read"]}` for viewer. A key that already has scopes, or has no
known role, is not touched. It runs in batches of 5,000 rows and is safe to run twice.

Why: a key with empty scopes now authorizes nothing. If skipped: every key minted without scopes answers 403.
(CHANGELOG: "Changed: an API key's scopes are enforced, and a key with no scopes is refused")

### C8. Migrate and re-baseline

    mix ecto.migrate
    MIX_ENV=test mix ecto.migrate
    mix samen.catalog.dump --output schema.dict.json

Run the comparison from C1 again; both outputs must be empty. Commit `schema.dict.json`. If your app has the default JSON:API
surface run `mix samen.verify.api_contract --version v1` and read any structural break before updating `api_contract.v1.json`.

Why: the gate compares the committed dictionary with the compiled resources. If skipped: gate step 1b fails with
`schema.dict.json is stale`.
(CHANGELOG: "Host action required (existing hosts and generated apps)", item 1)

### C9. Catalog meaning

1. Copy the new `ci.sh` from the reference app (it has the new steps), or add to yours, after the `schema.dict.json` drift check,
   `echo "--- step 1c: mix samen.verify.catalog_meaning"` and `mix samen.verify.catalog_meaning`.
2. Run `mix samen.verify.catalog_meaning --init` once and commit `catalog_meaning.baseline`. If your own text has a quality
   violation (under three words, a `vt_`, a restated name) `--init` still writes the file but exits 1; fix the text and run it
   again.
3. Describe your own resources and fields (`description:` on each attribute, `resource do description ... end`,
   `pii_attribute ... description:`); the reference app's `lib/<app>/vertical.ex` and `aggregate.ex` show the shape. Then run
   `mix samen.verify.catalog_meaning --shrink` and `mix samen.catalog.dump --output schema.dict.json`, and commit.
4. Scripts that call `mix samen.gen.resource` must pass `--description "..."`.

Why: generated apps now run the verifier. If skipped: nothing fails until you add the step; once added without a baseline it runs
strict and lists every undescribed table.
(CHANGELOG: "Added: generators emit described resources (ADR-043 §8a, A3)"; "Added: the catalog-meaning verifier (ADR-043 §8a, A2)")

## D. Code changes

### D1. Mount `Samen.Web.SecureHeaders`

Add `plug(Samen.Web.SecureHeaders)` to the `:browser` pipeline of your router.

Find it: `rg -n 'pipeline :browser' lib`

Why: security headers and a conservative CSP (`frame-ancestors 'self'`). If skipped: those headers are not sent.
(CHANGELOG: "Host action required (existing hosts and generated apps)", item 2)

### D2. Pass the layout on your own `live_session`s

Add `layout: {Samen.Web.Layouts, :app}` to every `live_session` you wrote yourself. The framework route macros already do.

Find it: `rg -n 'live_session' lib`

Why: the flash group and connection banner render once, from the layout. If skipped: those pages lose them.
(CHANGELOG: "Host action required (existing hosts and generated apps)", item 3)

### D3. Give mounts an identity namespace and keep tenant pages behind the gate

Set the `:identity_namespace` label (the module that holds your Identity scope; `<App>.Operator` in a generated app) on every
mount whose pages act as the signed-in person: Billing, Notifications, Operator, CRM, CSV, files, Support, Marketing, Chat. The
reference app's `router.ex` shows it. Mount `ContactsLive`, `CompaniesLive` and `ProfileLive` only in a `live_session` that
carries `{Samen.Web.TenantAuthz, :require_tenant}`; the `samen_*_routes` macros do this. A mount with no resolvable `otp_app`
used to count as disarmed; set the `:otp_app` label on it.

Find it: `rg -n 'samen_.*_routes|samen_module_routes|labels:' lib`

Why: the person's role is read from `<namespace>.User` and its membership. If skipped: on an armed host every signed-in user sees
the unavailable state (or a 503) and the failure is logged on each request; a socket the tenant gate never ran on is refused.
(CHANGELOG: "Fixed: authorization and honesty round 5 ...", upgrade notes 2 and 3; "Reads that lie, phase 2 (WP6)", host action;
`docs/guides/generators.md`)

### D4. Let your own browser auth gate accept the framework session

If you copied `DriftwoodWeb.Auth` or `PawChartWeb.Auth`, add the clause that treats a live `samen_session_token` session as
authenticated. A new framework sign-in now drops the legacy `samen_current_user` key, and logout clears both.

Find it: `rg -n 'samen_current_user|samen_session_token' lib`

Why: the framework login writes only `samen_session_token`. If skipped: every framework login redirects to `/login`.
(CHANGELOG: "Fixed: authorization and honesty round 5 ...", the entry "Fixed: an armed host redirected every framework login to `/login`")

### D5. Re-generate or hand-apply the API-key plug

Compare `lib/<app>_web/api/key_auth_plug.ex` with the reference app and apply the differences (for an unmodified generated plug,
copy the reference file). The lookup becomes `Samen.Scope.ApiKey.active_query(<App>.Operator.ApiKey, digest, now)` (it filters
revoked and expired keys), the selected fields include `org_id`, the role comes from `Samen.Scope.ApiKey.acting_role/1` then
`effective_role/2`, and a failed key or membership read answers 503 through `Samen.Web.Api.KeyCheckUnavailable`. Keep the
`# authz-scope:` marker on the read. Any custom key check should use the same functions. A key resource with no `:expires_at`
column defines `def samen_key_expiryless?, do: true`.

Find it: `rg -n 'token_digest|revoked_at|ApiKey' lib`

Why: the role cap and the active-membership check exist only in the new plug. If skipped: an old plug that did not filter expiry
keeps authenticating expired keys, and keys of removed or demoted minters keep their old rank.
(CHANGELOG: "Security: identity authorization (evaluation 2026-11-13, findings 1, 5, 7, 10, 13, 16)"; "Security: identity authorization, round 2 ...";
"Security: identity authorization, round 3 (second read-only review ...)"; "Fixed: hardening batch 3 ...")

### D6. Code that writes API keys

- `ApiKey :create` needs `minter_role` and a `membership_id` that is the actor's own active membership; `minter_role` cannot be
  above that membership's current role.
- `ApiKey :update` accepts `expires_at` only and can only shorten it. To widen a key, mint a new one. Revoke with `:revoke`, not
  by setting `revoked_at`.
- `ApiKey :mark_used` is system-only: stamp `last_used_at` from the key check with `authorize?: false`.
- Minting with an empty scope map is refused (`{:error, :no_scopes}`). A scope key is `"all"`, `"<family>"` or `"<family>.<type>"`
  and its value a list of `"read"` and `"write"`. A script or test that creates a key with `%{}` scopes needs `%{"all" => ["read"]}`
  or its family.
- A resource of your own with `extensions: [AshJsonApi.Resource]` needs `authorizers: [Ash.Policy.Authorizer]`.
- A key acts with the lower of its scopes and its role.

Find it: `rg -n 'revoked_at|mark_used|minter_role|scopes|AshJsonApi.Resource|last_used_at' lib test priv`

Why: see each line. If skipped: `:create` or `:update` returns a forbidden or no-such-input error, keys answer 403, and a JSON:API
resource without an authorizer stops compiling.
(CHANGELOG: "Changed: an API key's scopes are enforced, and a key with no scopes is refused"; "Security: identity authorization, round 2 ...",
"Upgrade notes (everything in this security series, for a host or a generated app)"; "Security: identity authorization, round 3 (role management, sessions, invitations, org slugs and API keys)")

### D7. Readiness endpoint

Replace a hand-written `/readyz` body with `{status, body} = Samen.Web.Readiness.report(repo: <App>.Repo)` and
`send_resp(conn, status, body)`.

Find it: `rg -n 'readyz|Readiness' lib`

Why: the report adds the `partitions:` and `single_node:` advisory lines when they have something to say. If skipped: those lines
are missing. (CHANGELOG: "Host action required (existing hosts and generated apps)", items 0 and 8)

### D8. Seed tasks

Boot seed tasks with `Samen.SeedBoot.start!(:<app>, <App>Web.Endpoint)` as the first line of `run/1`, and delete
`@requirements ["app.start"]`.

Find it: `rg -n '@requirements' lib/mix`

Why: otherwise the task starts the HTTP listener. If skipped: `mix <app>.seed` dies with `:eaddrinuse` while the dev server runs.
(CHANGELOG: "Host action required (existing hosts and generated apps)", item 9)

### D9. Organisation pinning

An authorized update cannot change `org_id`, and an actor's create must carry the actor's own `org_id`.

- An update that sends `org_id: <the same org>` as input fails with `org_id cannot be changed`: drop the input.
- An update that writes a foreign key on a record whose `org_id` is not loaded is refused. Load it with `Ash.load!(record, :org_id)`.
- `Samen.OrgIdPinnedGuard.walk/3`: a guard test that passes `repos:` keeps working; list actions that set `org_id` in a
  `before_action` in `hook_set:` with a reason and a named test.

Find it: `rg -n 'org_id' lib test | rg -i 'update|input|params'`

Why: before, any authorized update could move a row into another organisation. If skipped: the errors above. Code running with
`authorize?: false` is not affected.
(CHANGELOG: "Security: authorization and erasure, round 4"; "Fixed: flakes and guards round 5 ...")

### D10. Identity writes

- `Membership :create` refuses a second row for the same `org_id` and `user_id`; change the existing row's role or status.
- `Membership :update` accepts `role` and `status` only; `User :update` and `Role :update` no longer accept `org_id`.
- A membership write must out-rank both the stored role and the one being set, so an admin cannot update, suspend or destroy an
  owner's or a peer admin's membership and an owner cannot touch another owner's.
- `Org :create` accepts `name` and `slug` only; `Org :update` accepts `name`, `slug` and `max_concurrent_sessions` and needs an
  admin; `Org :destroy` needs an owner. Seeds set `plan`, `org_id` and `onboarded_at` with `force_change_attribute` under
  `authorize?: false`. A slug equal to another org's slug or id is refused (`slug is already taken`).
- `Org :open_account` needs `context: %{samen_operator_write: true}`, set only after your own operator-role check.
- `Invitation :update` takes no input; `:create` accepts `org_id`, `role` and `email` only (use `Samen.Identity.Invite.create/3`);
  `:destroy` needs an admin; `:revoke` needs a pending row.
- `Samen.Web.Onboarding.select_plan/4` needs an owner and is closed once `onboarded_at` is set.
- `Samen.Web.Settings.Profile.update/4` returns `{:error, :forbidden}` unless the scope's actor is the user being edited; build the
  scope with `Samen.Web.Settings.Reads.user_scope/3`.
- `Samen.Scopes.Identity.Blueprint.define_user` takes the membership module; `use Samen.Scopes.Identity` passes it.
- A membership whose `status` is not `"active"` confers no role and no org access. A host seam that lists orgs from its own
  membership table must filter on `status == "active"`.

Find it: `rg -n 'Membership|Invitation|Org\b|:open_account|select_plan|define_user' lib test priv`

Why: the old rules let an admin raise a role, rewrite an org id or demote an owner. If skipped: the errors named above.
(CHANGELOG: "Security: identity authorization, round 3 (role management, sessions, invitations, org slugs and API keys)";
"Security: identity authorization, round 3 (second read-only review ...)"; "Security: authorization and erasure, round 4";
"Security: identity authorization (evaluation 2026-11-13, findings 1, 5, 7, 10, 13, 16)")

### D11. Actions now refused to a tenant actor

These are system actions. Run them with `authorize?: false`, or let the scheduler trigger them.

- Outreach `Enrollment :advance_due`, `:due_scan`, `:system_advance`; `StepSend :queue`, `:mark`, `:requeue`.
- Automation `Workflow :scan_due`, `:dispatch_due`, `:operator_kill`, `:operator_rearm`; `Reminder :due_scan`, `:fire`;
  `Escalation :due_scan`, `:advance_step`, `:open`, `:refresh`, `:resolve`, `:cancel`; the run log `:create` and `:update`.
- AI agent `Run :due_scan`, `:resume_due`, `:expire_due` and every other agent `Run` write.
- Mailbox `Connection` and `MailMessage` create, update and destroy.
- `File :promote`.
- `Analytics.ProductEvent :append`: call `Samen.Analytics.track/1`.
- `Notification` create: use `Samen.Notifications.Engine`.
- `Samen.Automation.Health.kill` and `rearm` take the org id second: `kill(operator, org_id, workflow_id, opts)`.

Find it: `rg -n 'due_scan|advance_due|system_advance|operator_kill|operator_rearm|:requeue|:append|Health\.(kill|rearm)|Mailbox' lib test`

Why: each was open to every actor. If skipped: a forbidden error, or for `Health.kill/3` a function-clause error.
(CHANGELOG: "Fixed: authorization and honesty round 5 ...", the entries on Outreach and Mailbox, on the Automation and AI-agent system
actions, and "Fixed: an admin's direct `Analytics.ProductEvent :append` ..."; "Host action required ...", item 4)

### D12. Workflows and agent runs act with the owner's real role

Wire the membership seam: `config :samen_core, Samen.AI.Agent, approver_membership: <App>.Operator.Membership` (a resource module,
or `{Module, :function}` of arity 2). A workflow and an agent run now act with the role their owner holds now. An owner who is a
viewer cannot make member-only writes, and an owner with no active membership in the org stops the run with `owner_unavailable`.
People who start agent runs need an active membership. Do F5.

Find it: `rg -n 'approver_membership|Samen.AI.Agent|Automation' config lib`

Why: before, a run used an unchecked role. If skipped: an unwired host retries a workflow run and ends it as an internal error, and
an agent run stops with `owner_unavailable`.
(CHANGELOG: "Fixed: the Automation engine's guards, owner role, schedule scan, escalation advance and webhook delivery ids")

### D13. Roles that moved

Check every place your own code or UI writes these. The role is the lowest that may now do it. Reads stay open to every active
member. A viewer is a viewer everywhere: it used to act as a member on the CRM, Support, Billing, Marketing and Work pages, CSV
export, file bytes and the profile page.

| Write | Role |
|---|---|
| CRM Person create, update, destroy, archive, restore | member |
| Work task and project create, archive, status | member |
| Outreach `Enrollment :enroll`, `:pause`, `:resume`, `:stop` | member |
| Support ticket, conversation and status writes; reply; author or edit a KB article | member |
| Create a billing customer | member |
| Upload a file; start a chat conversation; post a chat message | member |
| Publish a KB article | admin |
| Subscription, plan, price, invoice and entitlement writes; subscribe; open the payment portal | admin |
| Campaign and segment writes; send a campaign to a segment | admin |
| Automation builder writes; feature-flag writes | admin |
| Mint or revoke an API key; invite or revoke an invitation; decide a reveal request | admin |
| Onboarding wizard writes; load sample data; flip the chat identity disclosure | admin |
| `Org :update`; `Invitation :destroy`; create a `User` row | admin |
| Another user's profile, anyone's `status`, destroy a user | admin, strictly above the target's highest role |
| Destroy a notification addressed to the organisation | admin |
| `Org :destroy`; choose the plan in onboarding | owner |
| Operator console "New account" | `:operator_admin` or `:operator_support` |

A tenant page opened on the operator plane is read-only; an operator impersonates to act in a tenant.

Find it: `rg -n 'role: :member|role: :admin|:viewer|write_scope|admin_scope|system_scope' lib`

Why: the old pages acted as a fixed member. If skipped: a forbidden error where a member acted before.
(CHANGELOG: "Fixed: authorization and honesty round 5 ..."; "Changed: loading sample data is an admin's and runs as the person";
"Changed: the settings pages and the onboarding wizard act as the signed-in person"; "Changed: the automation builder acts as the
signed-in person; every write is an admin's"; "Changed: the file upload and preview pages act as the signed-in person"; "Changed: the
chat inbox and room act as the signed-in person"; "Changed: the feature-flags settings page and the calendar export act as the
signed-in person"; "Changed: a tenant page on the operator plane is read-only")

### D14. Pages and helpers that took an org id now take a scope

- `Samen.Web.SampleData.load(mount, org_id, scope)` and `Samen.Web.FirstRun.first_run?(mount, org_id, scope)` take the acting scope
  as a third argument; `load` refuses below admin.
- `Samen.Web.TenantActor.write_scope/3` raises `ArgumentError` on an armed tenant mount for anything that is not a `%Samen.Scope{}`,
  and answers a read-only scope on the operator plane. Pass the page's own acting scope.
- `Billing.Reads`, `Marketing.Reads` and `Support.KbReads` `write_scope/3` answer a read-only scope on an operator mount.
- `Samen.Web.Support.KbReads.publish_article/3` also takes a `%Samen.Scope{}`; a member's publish is refused.
- If you copied `DriftwoodWeb.BrokerLive` (`dispatch_decision/2`, `create_load/2`, `update_load/3`, `delete_load/2`) or
  `PawChartWeb.ClinicReads` (`create_owner/2`, `update_owner/3`, `create_pet/2`, `update_pet/3`): they take the acting scope, and
  `broker_scope/1` and `tenant_scope/1` are gone.
- `Samen.Web.Operator.Impersonation.gate/3` and `gate_socket/3` can answer `:unavailable`: render a retryable error.
- Re-generate `--live` screens (`mix samen.gen.resource ... --live`) to get the role check before every event; an already
  generated screen keeps the old behaviour.

Find it: `rg -n 'SampleData|FirstRun|write_scope|publish_article|Impersonation\.gate|Mount\.scope|Plane\.scope' lib`

Why: the old arities acted as a fixed member. If skipped: function-clause errors at the call.
(CHANGELOG: "Changed: loading sample data is an admin's and runs as the person"; "Fixed: authorization and honesty round 5 ...";
"Fixed: a form built before a demotion or an organisation switch is never submitted with the authority it was built with";
"Changed: no write helper hands an admin role to the operator plane"; "Reads that lie, phase 2 (WP6)";
"Fixed: the broker console acts as the signed-in person"; "Fixed: the clinic page acts as the signed-in person")

### D15. Files

`File :create` and `:update` no longer take `status` or `archived_at`; `:update` takes `filename` and `metadata`. Promote with
`Samen.Files.promote/3`, rewrite content through `Samen.Files.upload/3`, archive and restore with the `:archive` and `:restore`
actions. Uploaded bytes are served with `X-Content-Type-Options: nosniff`, as an attachment under a sandboxing CSP unless the type
is png, jpeg, gif, webp, pdf or plain text.

Find it: `rg -n 'status: :active|archived_at|content_type|size_bytes|uploaded_by_id' lib test`

Why: a member could un-quarantine a file or serve it as HTML. If skipped: a no-such-input error.
(CHANGELOG: "Fixed: authorization and honesty round 5 ...", the entries "Fixed: a member could un-quarantine a File." and
"Fixed: the file-bytes and CSV-export routes answered 503 \"no mount\" on every host.")

### D16. Notifications

A user reads and marks read only their own notifications (and the rows addressed to the organisation, for a member or above). Only
`Samen.Notifications.Engine` creates them. An update takes `read_at` and `status` (`:read` only). A user writes only their own
`NotificationPreference`. The `:recipient_id` and `:current_user_id` mount labels and the `?recipient=` and `?user=` parameters
work only on a disarmed (dev) host: sign users in through the framework login. A chat participant who should be mentioned needs
`principal_id` (the per-org user id).

Find it: `rg -n 'Notification|recipient_id|current_user_id|principal_id' lib test`

Why: any member could read and write every recipient's rows. If skipped: empty inboxes for people the old labels named, and
forbidden errors on writes.
(CHANGELOG: "Fixed: authorization and honesty round 5 ...", the entry "Fixed: notifications were readable and writable across recipients.")

### D17. Smaller write rules

- `Tags.Tagging` must name a real, unarchived row of the same organisation, on every path including `authorize?: false`.
- `Primitives.SearchIndex` refuses a vault-routed field and a `resource_name` that is not a loaded Ash resource.
- `Calendar.Event` refuses `ends_at` before `starts_at` (equal is allowed, no end is allowed). An existing event can still be edited
  in other fields.
- `Samen.Web.SavedViews.Params.serialize/4` refuses filter-box text when a filter field is vault-routed.
- A `"vt_..."` string written to a vault field is plaintext and is encrypted. Only an internal `%Masked{}` bound to the record, vault
  and field means "already vaulted". An upsert-create on a PII resource is refused, and so is a PII write with no open
  transaction. `Samen.Vault.materialize/2` is removed: resolve through `Samen.Api.PiiResolution`.
- `Samen.Webhook.deliver/4` with `:multi` returns `{:ok, count, multi}`: run the returned multi. Without `:endpoints` it reads the
  org's unarchived endpoints from `:webhook_endpoint_module`; with neither configured it returns `{:error, :not_configured}`.
- `Samen.QueryBudget.over_threshold?/2` raises on an unreadable ledger. `Samen.Marketing.Consent.state/3` is deprecated: use
  `state_result/3`.
- Erasure checks blind-index coverage before it destroys a key (an unregistered `_bidx` column returns
  `{:error, {:blind_index_uncovered, ...}}`); `Samen.Erasure.pending/1` lists unfinished erasures; a subject export never decrypts
  secret-class vaults.

Find it: `rg -n 'Tagging|SearchIndex|Calendar.Event|SavedViews|vt_|materialize|Webhook.deliver|over_threshold|Consent.state|Erasure|Dsar' lib test priv`

Why: each closed a way to write across tenants or skip a check. If skipped: the error described.
(CHANGELOG: "Fixed: authorization and honesty round 5 ..."; "Security: vault tokens are bound to the record that holds them (High)";
"Kernel review fixes (samen_core, samen_web, demo, driftwood, pawchart)"; "Kernel honest reads (samen_core)";
"Security: authorization and erasure, round 4"; "Fixed: an erasure that failed after the key shred is resumable (AI derived context is withdrawn on the retry)")

### D18. Mount `/api/help` and the error hints

A host with a JSON:API adds two lines. In the API endpoint (`lib/<app>_web/api/endpoint.ex`), as the FIRST plug:

    plug(Samen.Api.Help.ErrorHints, router: <App>Web.Api.Router)

and in the router, beside the `/api/v1` forward (a Phoenix router; in a `Plug.Router` write `forward("/api/help", to: Samen.Api.Help.Endpoint, router: ..., key_auth: ...)`):

    forward("/api/help", Samen.Api.Help.Endpoint,
      router: <App>Web.Api.Router,
      key_auth: <App>Web.Api.KeyAuthPlug
    )

`key_auth` is the same key plug the API endpoint runs, and it must put the actor with its `:api_key` map on the conn (the demo, driftwood and
generated plugs do): an actor without the key map is answered `401`. `/api/help` then describes, for the key that asks, the resources, actions, fields and
relations it can use (JSON, or HTML on `Accept: text/html`). Each action carries `scope`, a scope map you can mint a key with
(`{"crm.contact": ["read"]}`), `also_granted_by` (the wider scope names that grant it) and `conditional` (allowed for some records only).
Each API error carries `meta._hint` and `links.about`. A generated app already has both.
Nothing else changes: no migration, no config. `plug` becomes a dependency of `samen_core` (your app already locks it).

Find it: `rg -n 'forward\(|Api.Router|Api.KeyAuthPlug' lib`

Why: without the mount the description is not served and errors carry no hint; with it a key learns its own authority and nothing it cannot use.
If skipped: `/api/help` answers 404 from your router and errors are the plain AshJsonApi bodies; nothing else breaks.
(CHANGELOG: "Added: `/api/help`, what a key can do, and hints on API errors")

## E. Test changes

### E1. Fixtures need active memberships

Every signed-in test user needs a user row and an active `Identity.Membership` row in the org the test acts in, with the role the
test expects. A viewer fixture is a viewer. A test that drives a page without a signed-in person on an armed host now gets the
denied state: log in as a real person with the right role. The generated `api_case` of v0.1.0 already creates the user and an
active membership.

Find it: `rg -n 'Membership|role:|login|samen_session_token' test`

Why: roles come from memberships. If skipped: tests that wrote through a page get a refusal.
(CHANGELOG: "Fixed: authorization and honesty round 5 ...", upgrade note 1; "Fixed: the Support, Billing and Marketing pages acted as a fixed `:member` ...")

### E2. Keys need scopes, a minter role and an active membership

Test helpers that create an API key pass `scopes:` (for example `%{"all" => ["read", "write"]}`), `minter_role:` and a
`membership_id` that is an active membership of the actor.

Find it: `rg -n 'ApiKey|minter|scopes' test`

(CHANGELOG: "Changed: an API key's scopes are enforced, and a key with no scopes is refused"; "Upgrade notes (everything in this
security series, for a host or a generated app)")

### E3. Tests that used a tenant actor for system work

Where a test enrolled contacts as a viewer, wrote mailbox rows, or ran a scan with a tenant actor, run it as a member or above, or
with `authorize?: false` for system actions. A test that changes a user's own `status` as that user must act as an admin over a
lower-ranked user instead.

Find it: `rg -n 'authorize\?: false|actor:' test`

(CHANGELOG: "Fixed: authorization and honesty round 5 ...", the entry on Outreach enrollments; "Security: authorization and erasure, round 4")

### E4. Shared sandbox and test database helpers (recommended)

Replace the raw `Sandbox.checkout` plus `Sandbox.mode(Repo, {:shared, self()})` pair in `DataCase` and `ApiCase` with
`Samen.TestSandbox.shared!(<App>.Repo)`. A test whose writes must commit calls `Samen.TestSandbox.auto!(<App>.Repo)`. Where
`test_helper.exs` and `priv/ci_bootstrap.exs` drop and create the database by hand, call `Samen.TestDb.reset!(Repo.config())`.

Find it: `rg -n 'Sandbox.mode|Sandbox.checkout|storage_down' test priv`

Why: the raw pair made the test process the owner (the `owner exited` flake). If skipped: nothing fails at once; tests can flake.
(CHANGELOG: "CI, tooling and the proof corpus"; observed in the upgrade test: the unchanged v0.1.0 test files still passed)

### E5. Vault-token assertions

`Samen.VaultTokenAssert.refute_vault_token/3`, `assert_vault_token/2` and `leaks/2` take binary or iodata only (`nil` flunks). Replace
a bare `~r/\bvt_/` match in API tests with `Samen.VaultTokenAssert.refute_vault_token(body, "message", boundary: true)`. If you copied
the guard tests (the `org_id` pin walk, the tenant-actor ratchet), copy them again from the new tree.

Find it: `rg -n 'vt_|VaultTokenAssert|OrgIdPinnedGuard|TenantActorGuard' test`

(CHANGELOG: "Fixed: flakes and guards round 5 ...")

## F. Data checks on a production database

Run these read-only queries on a copy or a replica before you deploy. Replace the abbrevs (`uoo_`, `uou_`, `uom_`, `uok_`, `uon_`)
with the Identity map of your `lib/<app>/operator.ex` (org, user, membership, api_key, invitation).

### F1. Users with no active membership

    SELECT u.uou_id, u.uou_org_id FROM uou_user u
    WHERE NOT EXISTS (SELECT 1 FROM uom_membership m
                      WHERE m.uom_user_id = u.uou_id AND m.uom_org_id = u.uou_org_id AND m.uom_status = 'active');

These people get the denied state on tenant pages, and 403 on CSV export and file bytes. Create their membership rows (D13 shows what
each role may do), or decide they lose access. Ask before choosing a role for anyone.

(CHANGELOG: "Fixed: authorization and honesty round 5 ...", upgrade note 1; "Security: identity authorization, round 3 (role management, sessions, invitations, org slugs and API keys)")

### F2. More than one membership for one user in one org

    SELECT uom_org_id, uom_user_id, count(*) FROM uom_membership GROUP BY 1, 2 HAVING count(*) > 1;

The resolver takes the lowest-ranked active row, so a second, lower row demotes the person. Keep one row.

(CHANGELOG: "Security: identity authorization, round 3 (role management, sessions, invitations, org slugs and API keys)")

### F3. API keys

    -- empty or null scopes (C7 backfills these; check what is left)
    SELECT uok_id FROM uok_api_key WHERE uok_scopes IS NULL OR uok_scopes = '{}'::jsonb;
    -- scopes with no write
    SELECT uok_id, uok_scopes FROM uok_api_key WHERE uok_scopes <> '{}'::jsonb AND uok_scopes::text NOT LIKE '%write%';
    -- no minter role
    SELECT uok_id FROM uok_api_key WHERE uok_minter_role IS NULL;
    -- minting membership missing or not active
    SELECT k.uok_id FROM uok_api_key k LEFT JOIN uom_membership m ON m.uom_id = k.uok_membership_id
    WHERE m.uom_id IS NULL OR m.uom_status <> 'active';
    -- keys with no expiry
    SELECT count(*) FROM uok_api_key WHERE uok_expires_at IS NULL;

- Empty scopes: a key with no role stays empty after C7 and is refused; re-mint it.
- No write in scopes: keys minted on the API-keys page with its old default of `read` only no longer write until re-minted.
- No minter role: refused at every key-check site; re-mint.
- Minter not active: the key stops authenticating.
- No expiry: stays non-expiring (there is no backfill); an update may give it a clamped expiry.

(CHANGELOG: "Changed: an API key's scopes are enforced, and a key with no scopes is refused"; "Upgrade notes (everything in this
security series, for a host or a generated app)")

### F4. Duplicate token digests

    SELECT uok_token_digest, count(*) FROM uok_api_key GROUP BY 1 HAVING count(*) > 1;

Run the same query for each `*_csat_survey_token` table and its digest column. Resolve duplicates before C6; the migration deletes
nothing.

(CHANGELOG: "Fixed: hardening batch 3 (database TLS, API-key digest uniqueness, expired API keys)")

### F5. Workflow and agent owners

If you mount Automation or run agents: list workflows, and agent runs in progress, whose owner has no active membership in the
workflow's or run's org. After the upgrade those stop with `owner_unavailable`. Reassign the owner, or accept that they stop. Ask
before reassigning.

(CHANGELOG: "Fixed: the Automation engine's guards, owner role, schedule scan, escalation advance and webhook delivery ids")

### F6. Organisation slugs

    SELECT a.uoo_id, b.uoo_id FROM uoo_org a JOIN uoo_org b ON a.uoo_id < b.uoo_id
    AND (lower(btrim(a.uoo_slug)) = lower(btrim(b.uoo_slug))
      OR lower(btrim(a.uoo_slug)) = b.uoo_id::text OR lower(btrim(b.uoo_slug)) = a.uoo_id::text);

New writes are refused; rows that already collide are not changed.

(CHANGELOG: "Security: identity authorization, round 3 (role management, sessions, invitations, org slugs and API keys)")

### F7. Invitations, calendar events, legacy vault cells and tickets

- `SELECT uon_id, uon_status FROM uon_invitation WHERE uon_status NOT IN ('pending','accepted','revoked','expired');`
- Calendar events whose `ends_at` is before `starts_at`: they can be edited, but an edit that touches either instant must leave
  them ordered.
- `mix samen.verify.vault_token_binding` against the database lists cells that do not belong to their record
  (`foreign_subject`, `field_mismatch`, `dangling_token`, `non_token_value`, `shared_token`). A legacy cell holding plaintext that
  starts with `vt_` blocks updates of a versioned record with an explicit error; the remedy is in `docs/guides/gate-failures.md`.
- Tickets with tags, before you drop or move the column (C2).

(CHANGELOG: "Security: identity authorization, round 3 (role management, sessions, invitations, org slugs and API keys)";
"Fixed: authorization and honesty round 5 ..."; "Security: vault tokens are bound to the record that holds them (High)")

### F8. After the migrations

- `mix samen.verify.indexes` against production: it counts only a valid, ready index. A `CREATE INDEX CONCURRENTLY` that failed
  leaves an invalid index; the migration drops it and builds it again on the next run.
- Check the `aud_event` DEFAULT partition holds no rows you did not expect.
- Read the output of the reveal-request backfill: it counts requests whose state could not be derived and left `pending`.

(CHANGELOG: "Tenant indexes (ARCH-4)"; "Audit partition hardening (ARCH-9)"; "Fixed: kernel phase D, honest reads ...")

## G. Verify

### G1. Compile and test

    mix compile --force --warnings-as-errors
    MIX_ENV=test mix test

The number of tests passed must be at least the number you wrote down in A1.

### G2. The gate

    MIX_ENV=test bash ci.sh

It must end with `<app> CI gate: ALL PASSED`. For a generated app it now has 19 steps; the added ones are `catalog_meaning`,
`oban_queues`, `read_scope`, `indexes`, `erasure_completeness`, `no_pan_columns`, `ai_prompt_masking`, `replay_schema` and
`signals_no_pii`. Copy the new `ci.sh` from the reference app if yours lacks them.

### G3. Run it

Start the app and request `/readyz`: it answers 200. A browser page carries a `content-security-policy` header with
`frame-ancestors 'self'`. `/api/v1/...` without a key answers 403. Seed with `mix <app>.seed` while the dev server runs: no
`:eaddrinuse`.

### G4. Sign in as each role

Sign in as an owner, an admin, a member and a viewer and try one write in each area your app uses. A viewer must see no write
control. Compare with the table in D13.

## How this guide was tested

This is what was run, stated as fact.

**Setup.** A detached worktree at tag `v0.1.0` generated an app with its own generator:
`mix samen.gen.app --module Upg014 --prefix ug --abbrev ugr --web --api`. Its gate (`MIX_ENV=test bash ci.sh`, 18 steps) and its 7 tests
passed on v0.1.0. A development database was created, migrated and seeded with `mix upg014.seed`. The app's `mix.exs` was then pointed at a
second detached worktree of the commit this guide was written on, so the real checkout's abbrev registry was not written, and the guide was
followed step by step. The app mounts Billing, Primitives, and the operator Identity, Billing and Support scopes, and has the API surface. It
has no CRM, Work, Chat, Marketing, Automation or agent scope, no `--deploy` layer and no user code beyond the generated files.

**Result.** After the steps below the app compiled with `--warnings-as-errors`, `mix ecto.migrate` ran clean on the development database and
from nothing on the test database, the comparison in C1 was empty in both directions, and `MIX_ENV=test bash ci.sh` ended
`CI gate: ALL PASSED` with 19 steps and 7 tests passed. The unchanged v0.1.0 test files also passed (7 tests) against the upgraded code.

**What the first draft of this guide got wrong or lacked, found by following it.** The abbrev registry step (A4) was missing: the compile
failed on the app's abbrevs. The reference-app command (A5) failed without `--no-compile`. The Ash string-length setting (B2), the new mount
abbrevs (B3) and `config/prod.exs` with the logger keep-list (B9) were missing; each stopped the compile or the gate. The reveal action (B4)
stops compilation, so it moved ahead of the generators. `samen.gen.reveal_requests` needs `--no-approvals` on an app with no approvals engine
(C4). Running the generators back to back wrote two migrations with one version and `mix ecto.migrate` refused (the `--timestamp` note). The
CSAT digest migration failed because its table did not exist yet. The migrations the CHANGELOG names were not the whole schema gap: the app
was missing 8 tables and 56 columns, none of them named as host actions, which is why C1 and C2 exist. Two gaps had no migration to copy: the
Billing provider column renames and the ticket `tags` column (C2). The draft said `/readyz` always carries `partitions:` and `single_node:`
lines; it answers a plain `ready` when there is nothing to advise.

**Exercised by this test:** A1 to A5, B1 to B4, B7, B9, C1 to C9 (C3 only through the money migration on an empty Price table), D1, D3, D5,
D7, D8, E4, F1 to F4 and F6 to F8 (F1, F2, F3 and F6 against rows planted for them; F4 and the invitation query returned no rows), G1 to G3.
The key-scopes backfill (C7) was run on planted keys: empty scopes became read and write for an admin key and read for a viewer key, a key that
already had scopes was left alone, and a key with no minter role stayed empty.

**Not run by the upgrade test:** D18 (mount `/api/help`) comes from the CHANGELOG and the build, not from the upgrade test, which was run before `/api/help` existed.

**Not applicable to the test app, so not exercised:** B5, B6, B8, B10, B11, D2, D4, D6, D9 to D12, D14 to D17, E1 to E3, E5 (for E1 and E2 the
generated test helpers already create a user with an active membership and mint keys with scopes), F5.

**Could not be exercised:** a production boot, TLS to a real database, Fly, the Oban `BootRun` path, replay, approvals, the AI agent loop,
workflows, the CRM, Work, Chat, Marketing and tenant Support pages, signed-in role behaviour in a browser (G4), any data volume, the
`CONCURRENTLY` index builds and the reveal-request backfill on populated tables, and the money, Activity and CMS data conversions with rows.
The steps for those come from the CHANGELOG alone.

**Order.** The test applied the draft in order and fixed it where it failed. The final text has the order that worked; it was not run again
from the start on a fresh app.
