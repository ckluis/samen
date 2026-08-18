# ADR-005 — Extract the `aud_chain` operator-plane migration into a shared core helper

- **Status:** Accepted (implemented)
- **Date:** 2026-07-07
- **Task:** T6.1 (extraction retro, plan §7 Phase 6). Item **A4** in
  `docs/extraction-retro.md`.
- **Deciders:** opus (T6.1), grounded in the Gate-5 carry-to-P6 item ("the `aud_chain`
  migration is not auto-generated when a host mounts the operator plane" —
  `docs/gate-5-report.md` fix-tasks; `docs/claim-evidence.md` C7).
- **Relates to:** ADR-002 (the `aud_chain` hash-chain design this migration deploys),
  ADR-004 (scope packaging — migrations ship as host-run templates, the pattern this
  follows), S0.4 / `Samen.Migration` (catalog-in-migration-transaction).

---

## 1 · Context — the copy-paste the retro found

`aud_chain` is the tamper-evident, tenant-readable, operator-uneditable hash chain (ADR-002):
the security-critical table that makes the control plane's "immutable AND crypto-shreddable"
claim real. Every host that mounts the operator plane needs it.

I diffed the three copies that existed after Phase 5:

- `samen_core/priv/test_repo/migrations/20260707020000_aud_chain.exs`
- `demo/priv/repo/migrations/20260707030000_aud_chain.exs`
- `driftwood/priv/repo/migrations/20260707200000_aud_chain.exs`

They were **byte-identical** modulo the module name and the `otp_app` atom used to read
`:aud_event_app_role`: the same `CREATE TABLE aud_chain`, the same dense per-org
`UNIQUE (ach_org_id, ach_seq)` index, the same tip-lookup index, the same append-only trigger +
`aud_chain_enforce_append_only()` function, the same `REVOKE UPDATE, DELETE`, and the same 15
`tam_table`/`fld_field` catalog rows written in the same transaction.

This is the textbook Rule-of-Three signal: **three** independent copies of one load-bearing,
security-critical DDL. A column add or a trigger fix had to land in three places and could
silently drift — and a *silent* drift in the append-only enforcement of the audit chain is
exactly the kind of hole the whole substrate exists to prevent. Driftwood forced the third
copy (T5.4 needed the table to prove the chain verifies post-shred), which is what tipped this
from "two copies, tolerable" to "extract now."

## 2 · Why extract-now (and not defer)

Against the extraction-retro's own counting rule (demo + driftwood = 2, be conservative), this
one clears the bar decisively:

1. **Three real, byte-identical copies** — not "two of my hosts agree." The substrate's own test
   repo is the genuine third use.
2. **Security-critical + drift-hazardous** — a divergence in the append-only trigger or the
   REVOKE between hosts is a real audit-integrity hazard, not a cosmetic duplication.
3. **The shape is stable** — the DDL has not changed since T4.3; `Samen.AuditChain.Entry` pins
   the column set; there is no open design question.
4. **Small and safe** — a pure-body helper + three 4-line wrappers, fully testable, zero change
   to the emitted SQL (verified: the three hosts still migrate identically and all suites stay
   green).

## 3 · The decision

**The full `aud_chain` migration body lives ONCE in `Samen.OperatorPlane.Migration`
(`samen_core/lib/samen/operator_plane/migration.ex`). A host migration is now a thin wrapper:**

```elixir
defmodule MyApp.Repo.Migrations.AudChain do
  use Ecto.Migration

  @app_role Application.compile_env(:my_app, :aud_event_app_role, "clank")

  def up,   do: Samen.OperatorPlane.Migration.create_aud_chain(@app_role)
  def down, do: Samen.OperatorPlane.Migration.drop_aud_chain(@app_role)
end
```

`create_aud_chain/1` emits (into the host migration's transaction) the table, both indexes, the
append-only trigger + function, the `REVOKE UPDATE, DELETE FROM <app_role>`, and the 15
same-transaction catalog rows. `drop_aud_chain/1` is its exact inverse. Every `execute/2` ships
a reverse clause.

### Why the host still owns the wrapper module

Three things are irreducibly the host's, so the module (not a `mix` task or a fully-generated
file) stays in the host's `priv/repo/migrations/`:

- **the `otp_app`** — the append-only `REVOKE`/`GRANT` must name the *host's* Postgres role
  (`:aud_event_app_role`), which is host config;
- **the migration position** — `aud_chain` must run after the host's catalog bootstrap (so the
  same-transaction `tam_table`/`fld_field` INSERTs have somewhere to go) and after `aud_event`;
- **the repo transaction** — the DDL + catalog INSERTs must execute in the *host's* repo's
  migration transaction (the S0.4 invariant), which only a migration *in the host* provides.

The helper emits the **body**; the host owns the **module**. This mirrors ADR-004's "migrations
ship as host-run templates" decision exactly.

### Two anti-drift guardrails built into the helper

- **Field list derived, single source.** The 15 `ach_` columns live in one `@aud_chain_fields`
  in the helper — the same columns backing `Samen.AuditChain.Entry`. A `describe "field parity"`
  test asserts the extracted list equals the schema's `ach_` source columns exactly, so the DDL
  cannot silently drift from the schema.
- **SQL-injection gate on the role name.** `app_role` is interpolated into `REVOKE`/`GRANT` DDL.
  It is developer-controlled, never user input, but `safe_role!/1` still hard-gates it to a plain
  (optionally double-quoted) identifier and **fails closed** on anything else — refusing to emit
  an injectable migration.

## 4 · Red paths + anti-tautology (HARD RULE 2)

`samen_core/test/operator_plane_migration_test.exs` (10 tests, all green), run end-to-end against
a **throwaway database** (`samen_core_opmigration_scratch`, created + dropped by the test) so the
DB-level trigger/role/catalog effects are exercised for real:

| Guarantee | Red path (must-fail) | Non-vacuous control |
|---|---|---|
| Append-only enforcement | the trigger REFUSES an `UPDATE` and a `DELETE` (`Postgrex.Error ~r/aud_chain is append-only/`) | a normal `INSERT` SUCCEEDS on the same table |
| Reversibility | `down/0` leaves **zero** orphaned `tam_table`/`fld_field` rows | the same table had 1 tam + 15 fld rows while up |
| Injection safety | `create_aud_chain/1` REFUSES `"clank; DROP TABLE tam_table; --"` and `"app role"` (`ArgumentError ~r/unsafe Postgres role name/`) | plain + double-quoted roles pass the gate |
| Schema parity | extracted field list == `Samen.AuditChain.Entry` `ach_` sources (fails on drift) | — |

**Anti-tautology probe (this session, project-local `.t61_scratch/`, reverted byte-identical,
md5 `d96d8ec46333d82b43fbdeead535ce61`):** I replaced the trigger's `RAISE EXCEPTION` body with
`RETURN OLD` (a no-op). The two append-only red paths **FLIPPED to failing** ("Expected exception
Postgrex.Error but nothing was raised") while the positive INSERT control stayed green — proving
the red paths exercise the real DB trigger, not a tautology. Reverted; md5 restored; all 10 green
again; scratch removed.

## 5 · Consequences

**Positive**
- One canonical `aud_chain` DDL; a fix or a column add lands once and reaches every host on a
  `samen_core` bump + a rerun of the (unchanged) host migration.
- The security-critical append-only enforcement can no longer drift silently between hosts.
- The three host migrations shrank from ~135–165 lines each to ~30 (mostly moduledoc).

**Negative / accepted**
- The helper calls `Ecto.Migration.execute/1,2` via `apply/3` (it is a plain module, not a
  `use Ecto.Migration` module). This works because a host migration that calls it already has the
  migration runtime active; documented in the moduledoc. A host that calls it *outside* a
  migration gets a clear runtime error, not a silent misfire.
- The host must still keep its wrapper migration in the right position (after catalog + aud_event).
  Documented in the moduledoc's usage example.

**Neutral**
- Emitted SQL is unchanged — verified by the three hosts migrating identically and all suites
  green before/after.

## 6 · Follow-up (backlogged, NOT done here)

The adjacent operator-plane migrations Driftwood also copy-pasted (`imp_impersonation_session`,
`osp_operator_suspension`, `brl_reveal_ledger`, `brc_break_glass_anchor` — retro item **A9**) are
the **same copy-paste class**, but they are token-only/uncatalogued (lower drift hazard) and vary
more between hosts. They are backlogged (retro §D, P1) to be extracted together behind a
`mix samen.gen.operator_plane` generator (T6.4), which would fold `create_aud_chain/1` in as one
step. Deferred, not dropped — scoping it to a generator is the right shape and keeps this ADR's
change small and unambiguous per the scope-decomposition principle.
