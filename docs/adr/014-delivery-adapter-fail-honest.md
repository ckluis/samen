# ADR-014 — Outbound delivery adapter contract, fail-honest send semantics, and abbrev-derived suppression

- **Status:** Accepted (design; WS-A phase A1 implements this contract).
- **Date:** 2026-07-09
- **Task:** Kernel DESIGN for WS-A/G2 — a pluggable outbound-email delivery adapter behaviour in `samen_core`, replacement of the no-op send stub with **fail-honest** semantics (an unconfigured adapter must NEVER fake `:delivered`), and removal of the hardcoded `msp_suppression` table name in favour of an abbrev-derived check. Kernel-only; verticals inherit.
- **Deciders:** opus (kernel layer), grounded in the WS-A non-negotiables ("Delivery: an unconfigured adapter must FAIL (or queue-and-alert), never fake `delivered`"; "framework-first"; "samen_core stays web-dep-free").
- **Builds on:**
  - The existing `Samen.Scopes.Marketing.SendWorker` (`send_worker.ex` — Oban `:webhooks_out` queue, token-only args convention, `send_id` idempotency).
  - The Marketing blueprint `:create_checked` action + suppression check (`marketing/blueprint.ex:446–471`).
  - `Samen.Info.abbrev/1` (`info.ex:10–19` — reads the declared abbrev from the `[:samen]` DSL section) and the abbrev registry (`samen_core/priv/abbrev_registry.json`, ADR-006).
  - The vault reveal path (recipient email is revealed under a grant at delivery time, never in job args or the message struct).
- **Supersedes / touches:** replaces the `StubAdapter` unconditional-success behaviour and the literal `msp_suppression` SQL. `samen_web` untouched by this ADR (delivery is kernel; the operator-notification-on-block is wired by ADR-015's engine). Only sanctioned append to the registry is per-mount abbrev rows.

---

## 1 · Context — the send that lies

`SendWorker.perform/1` delegates to a configured adapter, defaulting to `StubAdapter.deliver/2`, which returns `:ok` and the send is marked `:delivered` **unconditionally** (`send_worker.ex:59–62`; harden H-1). A tenant runs a campaign, every send flips to `:delivered`, zero email leaves the system, and any test asserting "send → delivered" is green against a no-op (harden §2, "tautological success"). Separately, the suppression check embeds a literal `SELECT 1 FROM msp_suppression …` (`blueprint.ex:450–458`; harden H-4) — the `msp` abbrev is baked in, so a vertical mounting Marketing under any other abbrev (which ADR-006 FORCES) queries a non-existent table: a crash or a silent suppression bypass (a compliance leak).

Both are honest seams whose **default** is dishonest. This ADR makes the default fail-closed.

## 2 · Decision — the delivery adapter behaviour

**`Samen.Delivery.Adapter`** (new):

```
@callback configured?(config :: map()) :: boolean()
@callback deliver(message :: Samen.Delivery.Message.t(), config :: map()) ::
            {:ok, receipt :: map()} | {:error, reason :: term()}
```

**`Samen.Delivery.Message`** — token-only envelope: `send_id`, `org_id`, `to_subscriber_id`, `template_id`. The recipient email is looked up at `deliver/2` time via the vault reveal path under a grant — NEVER stored in the struct or Oban args (preserves the `send_worker` token-only-args invariant).

**Shipped adapters:**
- `Samen.Delivery.LocalSink` — dev/test. Persists/logs the rendered message and returns `{:ok, %{sink: true}}`. This is an HONEST "captured, not delivered" — it is only selected in dev/test.
- `Samen.Delivery.Smtp` / `Samen.Delivery.Api` — **skeleton**. `deliver/2` performs the real dispatch; `configured?/1` returns false when creds are absent, and `deliver/2` returns `{:error, :not_configured}` rather than faking success. Live-provider integration is an operator TODO.

## 3 · Decision — fail-honest send semantics

`SendWorker.perform/1` becomes:

1. Resolve the configured adapter. If **none configured AND `Mix.env() != :test`** → the send is set to `:blocked` (NOT `:delivered`), an audit event `marketing.send.blocked` is emitted, an operator notification fires (via ADR-015's engine), and the job returns `{:error, :adapter_unconfigured}` so Oban retries/alerts. **It never returns `:delivered`.**
2. `adapter.deliver/2 → {:ok, receipt}` → send `:delivered` with the receipt persisted.
3. `adapter.deliver/2 → {:error, reason}` → send `:failed` (retriable within `max_attempts`), provably NOT `:delivered`.

**Invariant D1:** `status == :delivered` ⟺ a configured adapter returned `{:ok, _}`. There is no code path from an unconfigured/failed adapter to `:delivered`.

## 4 · Decision — abbrev-derived suppression

Remove the literal SQL. Preferred form: an **Ash read on the Suppression resource** (`Ash.exists?`/`Ash.Query.filter(org_id == ^org and subscriber_id == ^sub and active == true)`), which inherits `OrgScope` and needs no table string at all. Where the resource isn't reachable at that expansion point, derive the names from the declared abbrev:

```
abbrev  = Samen.Info.abbrev(<SuppressionResource>)   # "msp", "xyz", …
table   = "#{abbrev}_suppression"
org_col = "#{abbrev}_org_id" ; sub_col = "#{abbrev}_subscriber_id" ; act_col = "#{abbrev}_active"
```

**Invariant D2:** the suppression check queries the table owned by the mounting blueprint's declared abbrev — no `msp` literal survives. Mounting under a different abbrev either finds the correct table or, if the resource is absent, fails closed (refuses the send), never silently allows it.

## 5 · Red paths & anti-tautology

- **RP-D1 (the fail-honest proof):** no adapter configured, non-`:test` env → send is `:blocked`, `marketing.send.blocked` audit present, operator notified, job errored. Asserts `status != :delivered`. Deletes the old vacuous "send→delivered" test.
- **RP-D2:** adapter returns `{:error, _}` → `status == :failed`, never `:delivered`.
- **RP-D3 (suppression under non-`msp`):** mount Marketing under abbrev `xyz`, insert an active `xyz_suppression` row, attempt a send → refused. Proves no crash and no silent bypass.
- **Anti-tautology:** flip the adapter to succeed and assert `:delivered` DOES occur — so RP-D1/RP-D2 are non-vacuous.

## 6 · Consequences
- **+** "Delivered" can no longer lie; the delivery seam is honest by default; suppression is mount-portable.
- **+** `samen_core` stays web-dep-free (the operator-notification-on-block goes through the notification engine's kernel record path; the inbox render is `samen_web`).
- **−** Verticals relying on the silent stub "delivering" in a non-test env will now see `:blocked` — intended; they must configure `LocalSink` (dev) or a real adapter. Documented as an expected behaviour change.
- **−** The `api_contract`/marketing test snapshots shift (expected delta), regenerated in the A1 commit.
- **Operator TODO:** real SMTP/ESP creds + provider integration for `Smtp`/`Api`.
