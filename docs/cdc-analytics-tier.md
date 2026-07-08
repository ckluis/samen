# The CDC analytics tier (optional ClickHouse mirror) — T6.5

> The core is Postgres-solid; ClickHouse is a power-up. One Postgres runs a real,
> profitable SaaS. The analytics tier is **opt-in per product, default off** — and
> you **never read a "current" value from it**. (vision doc, honest edges)

This document covers the optional ClickHouse CDC tier: what it is, the invariant
that makes it safe, how the destruction oracle scans it, the never-read-current
rule, and the operator TODO for wiring real ClickPipes.

There is **no ClickHouse in this environment**. T6.5 ships the *mechanism*, a
*faithful local simulation* (`Samen.Cdc.LocalPostgres` mirroring into a second
local Postgres schema), and a *production skeleton* (`Samen.Cdc.ClickHouse`,
`ecto_ch`, config-flagged, not connected). Never a faked pass.

## 1. The shape

```
live truth        = Postgres (primary repo)
analytics mirror  = ClickHouse (second ecto_ch repo), seconds-stale, via ClickPipes/PeerDB
```

The mirror is fed by native CDC off the append-only event stream. It is queried
through a second Ecto repo. Most products never turn it on; it is a dotted,
opt-in branch (doc line 635).

## 2. The token-only-downstream invariant (why the mirror is safe)

The mirror carries **token-blind rows only** — vault-FK `vt_*` tokens, bounded IDs,
enums, timestamps, numbers, metadata. **Never plaintext PII.** (doc line 637)

This is enforced by `Samen.Cdc.Projection`, the load-bearing, adapter-independent
mechanism:

- `Samen.Cdc.Projection.project(resource)` returns exactly the columns safe to
  mirror. A plaintext PII column (mask-unknown-by-default via the shared
  `Samen.Pii.Classification` oracle) is **excluded** — it never enters the pipe.
- `Samen.Cdc.Projection.assert_no_plaintext!(resource, requested)` **raises**
  `PlaintextInProjectionError` if a caller explicitly names a plaintext column for
  the mirror. This is the production analogue of a mis-scoped ClickPipes column
  allow-list.

Because the projection is pure structure, the *same* proof holds for the local
Postgres simulation and for a real ClickHouse mirror.

**Erasure for free.** Destroying a subject's external-KMS key renders that
subject's vault ciphertext undecryptable across the live, replica, backup/PITR,
**CDC-mirror**, rollup, and audit tiers *at once*. The mirror keeps the `vt_*`
tokens (append-only, seconds-stale) but they become **dangling** — the ciphertext
they point at is gone. The analytics plane inherits erasure without forking a
second compliance surface.

## 3. Opt-in / default off

The tier is off unless a host wires an adapter:

```elixir
# LOCAL / CI — the faithful simulation (mirrors into the `cdc_mirror` schema):
config :samen_core, :cdc,
  adapter: Samen.Cdc.LocalPostgres,
  repo: MyApp.Repo,
  schema: "cdc_mirror"          # optional; default "cdc_mirror"

# PRODUCTION — the real ClickHouse mirror (see §6 operator TODO):
config :samen_core, :cdc,
  adapter: Samen.Cdc.ClickHouse,
  repo: MyApp.CdcRepo           # an ecto_ch repo
```

With NO `:cdc` config, `Samen.Cdc.enabled?/0` is false, nothing mirrors, and the
destruction oracle's `cdc_mirror` tier emits a `:pass` stating the mirror is off.

The legacy `:cdc_mirror_repo` key (from the T2.9 stub) is honored: set WITHOUT a
`:cdc` adapter, it makes the oracle **fail closed** (a configured-but-unscanned
mirror is a gap, not a pass). Prefer `:cdc` going forward.

## 4. The destruction oracle's `cdc_mirror` tier (now ACTIVE)

`mix samen.verify.no_plaintext_pii --subject <uuid> --tiers all` runs the
post-shred oracle. The `cdc_mirror` tier
(`Samen.NoPlaintextPii.Tiers.PostShred.CdcMirror`) — a stub through Phase 5 — is
now **active**:

- **schema assertion** — every physical column on every mirror table must be in
  the token-blind projection. A non-projected physical column (e.g. an operator or
  a mis-scoped ClickPipes allow-list added `pat_job_title` to the mirror) is a
  `:violation`. This is the red path: *a plaintext PII column in the CDC
  projection FAILS the oracle's cdc_mirror tier.*
- **post-shred content scan** — for the erased subject, no mirror `vt_*` token
  still decrypts. Post-shred the mirror holds only **dangling tokens** (`:pass`
  reporting the count). A token that still decrypts is a `:violation`. This is the
  red path: *post-shred the mirror holds only dangling tokens.*
- **never-read-current attestation** — records that the analytics repo is governed
  by the never-read-current rule (§5).

When the tier is off, it emits a single `:pass`. Fail-closed throughout — a mirror
the oracle cannot introspect is a violation, never a silent all-clear.

## 5. The never-read-current rule

The mirror is seconds-stale by construction. Reading a value back and acting on it
as *current* (a balance, a status, a limit you enforce) is a correctness bug.
Enforced two ways:

- **Runtime chokepoint** — every `Samen.Cdc` adapter's `read_current/3` ALWAYS
  raises `Samen.Cdc.NeverReadCurrent.Violation`. There is no legitimate
  current-read path; the callback exists only to fail loudly.
- **Build-time lint** — `mix samen.verify.never_read_current` flags any read
  (`all/get/get_by/one/aggregate/exists?`) against the configured CDC repo in a
  module NOT marked as analytics. A legitimate report marks its module:

  ```elixir
  defmodule MyApp.Reports.Revenue do
    use Samen.Cdc.Analytics        # or: @cdc_analytics_read true
    def mrr, do: MyApp.CdcRepo.all(RevenueRollup)   # fine — it's a report
  end
  ```

  A CDC-repo read in an un-marked module is a `:current_read` violation (exit 1).

Honest edge: this is a dataflow *match*, not a sound proof (same caveat as
`pii_reads`). A read laundered through an opaque helper is an expected miss — keep
CDC-repo reads syntactically visible and mark the module that owns them.

## 6. Operator TODO — wiring real ClickPipes / `ecto_ch`

To turn the mirror on in a real deployment (doc line 635 "flip on the managed
clickhouse.com/cloud/postgres path"):

1. Add `{:ecto_ch, "~> 0.3"}` to the host app's deps.
2. Define the analytics repo:

   ```elixir
   defmodule MyApp.CdcRepo do
     use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.ClickHouse
   end
   ```

3. Provision a ClickHouse Cloud service and a **ClickPipes** (or PeerDB) CDC pipe
   from the primary Postgres. **Scope the pipe's column allow-list to
   `Samen.Cdc.Projection.project(resource)` output** — the pipe must mirror ONLY
   the projected token-blind columns. A `pii_` plaintext column in the pipe's
   column list is the exact red path the oracle catches; the allow-list is the
   production analogue of `assert_no_plaintext!/1`.

   > **OPERATOR TODO:** generate the ClickPipes table+column allow-list from
   > `Samen.Cdc.Projection.project(resource)` for each mirrored resource, and diff
   > it against the live pipe config in CI so a new plaintext column can never be
   > silently added to the pipe.

4. Wire it: `config :samen_core, :cdc, adapter: Samen.Cdc.ClickHouse, repo:
   MyApp.CdcRepo`.
5. Point the destruction oracle's `cdc_mirror` tier at it: `--tiers all` then scans
   the real mirror for token-only + post-shred unrecoverability. Because the mirror
   carries only `vt_*` tokens whose per-subject vault key is destroyed on erasure,
   a shred renders the mirrored rows undecryptable across the analytics tier "for
   free" — the same key-destruction that covers live/replica/backup/rollup/audit.

Until these steps are complete, `Samen.Cdc.ClickHouse` callbacks fail closed
(`:not_connected`, and `scan_no_plaintext/2` returns `{:leaks, …}`): an
enabled-but-unconnected mirror must never report a clean scan.

## 7. Files

| File | Role |
|---|---|
| `samen_core/lib/samen/cdc.ex` | `Samen.Cdc` behaviour + facade |
| `samen_core/lib/samen/cdc/projection.ex` | token-blind projection (load-bearing mechanism) |
| `samen_core/lib/samen/cdc/local_postgres.ex` | faithful local simulation adapter |
| `samen_core/lib/samen/cdc/click_house.ex` | production skeleton (`ecto_ch`, not connected) |
| `samen_core/lib/samen/cdc/config.ex` | opt-in / default-off wiring |
| `samen_core/lib/samen/cdc/never_read_current.ex` | never-read-current guard + lint |
| `samen_core/lib/samen/no_plaintext_pii/tiers/post_shred/cdc_mirror.ex` | the now-active oracle tier |
| `samen_core/lib/mix/tasks/samen.verify.never_read_current.ex` | the lint mix task |
| `samen_core/test/cdc_mirror_test.exs` | mechanism + oracle tier tests (green + red + anti-tautology) |
| `samen_core/test/cdc_never_read_current_test.exs` | lint tests (green + red + anti-tautology) |
