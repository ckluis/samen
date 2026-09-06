# ADR-038 — Adapter architecture: billing + delivery providers, webhook ingress, test posture

- **Status:** Accepted (design ADR; fixes the shared WS-B/WS-C adapter shape before either is built).
- **Date:** 2026-07-22
- **Task:** T17 (phase 2). Binding on T18–T26 (WS-B), T27–T30 + T94 + T95 (WS-C), T103
  (rate-limiting hardening); consulted by T31 (phase gate, INV-4 probe per §8.4).
- **Deciders:** fable (T17 orchestrator), grounded in ADR-037 §5.9/§5.12/§5.14 (binding input),
  ADR-035 §4.5 (manual-plug rate-limit shape), ADR-014/024/026 (fail-honest adapter precedents),
  `spec/full-saas-readiness.md` §WS-B + §WS-C + INV-1..6, `_orch/plan/spec-questions.md`
  (M1, M2, M11 rulings; c9, c10, c11 defaults), and the live seams:
  `samen_core/lib/samen/delivery/{adapter,smtp,local_sink,message,lifecycle}.ex`,
  `samen_core/lib/samen/scopes/billing/sync_adapter.ex`.
- **Operator enrichment (2026-07-22):** M1/M2 re-confirmed; NEW — a no-credential Postmark
  real-HTTP smoke lane using the public literal token `POSTMARK_API_TEST` (§7.4).

---

## 1 · Context

Phase 2 wires real money (Stripe) and real email (three ESPs) into a substrate whose whole
credibility rests on fail-honest seams and a vendor-free core. Two existing seams are the
precedents to extend, not bypass:

- `Samen.Delivery.Adapter` (ADR-014): `configured?/1` + `deliver/2`, `{:error, :not_configured}`
  when creds are absent, never a fake `{:ok, _}`. `Smtp`/`Api` are honest skeletons; `LocalSink`
  is the honest dev/test capture.
- `Samen.Scopes.Billing.SyncAdapter`: a push-shaped Stripe-sync behaviour whose default `Stub`
  returns fake `{:ok, %{stub: true}}` results — exactly the tautological-success shape ADR-014
  abolished for delivery. It predates the fail-honest contract and is **superseded** here (§3.6).

WS-B (B1–B10) and WS-C (C1–C4, C8) both need webhook ingress (signature, replay, DLQ), both need
a keyless CI story (M2), and both must keep `samen_core` vendor-free with claims that hold when
the adapter packages are absent (INV-4). Three Phase-1 verifiers (T01, T98 P3-2, T101) flagged
the same unwired gap — the ADOPTED-but-nowhere-enforced `ash_rate_limiter` — so this ADR also
binds the ingress/auth rate-limit design (§6) that T103 and T19 implement.

This ADR fixes shape only; no production code changes land with it.

## 2 · Architecture overview

```
                       internet
                          │
        ┌─────────────────┴──────────────────┐
        │  samen_web (framework, vendor-free)│
        │  /webhooks/:provider ingress plug  │──▶ Samen.Web.RateLimit (§6, ash_rate_limiter+Hammer)
        │  provider module from HOST config  │
        └───────┬───────────────────┬────────┘
                │ behaviour calls   │ behaviour calls
   ┌────────────▼─────┐   ┌─────────▼──────────────────────────────┐
   │ samen_stripe     │   │ samen_postmark · samen_ses · samen_resend │  ← vendor deps live HERE
   │ (Billing.Provider│   │ (Delivery.Provider impls, req HTTP)      │    (req, aws sig, …)
   │  impl, req HTTP) │   └─────────┬──────────────────────────────┘
   └────────────┬─────┘             │
                │  behaviours + mirror + reconciler + events defined in
   ┌────────────▼───────────────────▼────────────────────────────┐
   │ samen_core (kernel, ZERO vendor deps)                        │
   │ Samen.Billing.Provider · Samen.Delivery.Provider (contracts) │
   │ WebhookEvent (replay store + DLQ) · Billing mirror resources │
   │ EmailEvent · Suppression · fakes + conformance harness        │
   └──────────────────────────────────────────────────────────────┘
```

Split of responsibility, binding: **adapters translate and transport; core owns state and
convergence.** An adapter maps vendor payloads to normalized structs and performs vendor API
calls. It never writes the mirror; the core reconciler does (§3.4). This keeps every governed
write inside the chokepoints (WriteGuard, OrgScope, catalog) and keeps adapters stateless.

## 3 · `Samen.Billing.Provider` (core-defined behaviour)

Module: `samen_core/lib/samen/billing/provider.ex` (T18). Config-selected per host
(`config :samen_core, :billing_provider, {SamenStripe.Provider, config}`); misconfiguration
raises at boot per the ADR-024 `--deploy` precedent.

### 3.1 Callbacks

```elixir
@callback configured?(config :: map()) :: boolean()

# B2 — hosted checkout. attrs: %{org_id, plan_id, price_ref, success_url, cancel_url, customer_ref}
@callback create_checkout_session(attrs :: map(), config :: map()) ::
            {:ok, %{provider_session_id: String.t(), url: String.t()}} | {:error, term()}

# B5 — payment methods via HOSTED surfaces only (billing portal / setup session URL).
@callback create_portal_session(attrs :: map(), config :: map()) ::
            {:ok, %{url: String.t()}} | {:error, term()}

# B3 — lifecycle mutations initiated samen-side (cancel/change with proration behavior opts).
@callback cancel_subscription(provider_subscription_id :: String.t(), opts :: keyword(),
            config :: map()) :: {:ok, map()} | {:error, term()}
@callback change_subscription(provider_subscription_id :: String.t(), changes :: map(),
            config :: map()) :: {:ok, map()} | {:error, term()}

# Convergence primitive (§3.4): authoritative re-fetch, normalized to samen field names.
@callback fetch_object(kind :: :customer | :subscription | :invoice | :payment_method_summary,
            provider_id :: String.t(), config :: map()) ::
            {:ok, normalized :: map()} | {:error, :not_found | term()}

# B8 — metered usage. Each record carries an idempotency key derived from the UsageRecord id.
@callback report_usage(batch :: [map()], config :: map()) ::
            {:ok, %{reported: non_neg_integer()}} | {:error, term()}

# §5 ingress — vendor signature scheme + payload normalization live in the adapter.
@callback verify_and_parse_event(raw_body :: binary(), headers :: [{String.t(), String.t()}],
            config :: map()) ::
            {:ok, Samen.Billing.ProviderEvent.t()} |
            {:error, :invalid_signature | :stale_timestamp | :malformed | term()}

# §5.4 — PII pruning before the envelope is persisted (pure function; must not need creds).
@callback redact_payload(payload :: map()) :: map()
```

### 3.2 Fail-honest contract (ADR-014 shape, binding)

Every callback except `configured?/1` and `redact_payload/1` returns
`{:error, :not_configured}` when `configured?/1` is false — never a fake `{:ok, _}`, never a
partial success. A capability the vendor genuinely lacks returns `{:error, :not_implemented}`.
T18 ships the table test asserting this for every callback of an unconfigured provider; the
existing `files_storage_test.exs` sabotage discipline applies (a stub that claims success is the
lie the gates test for).

### 3.3 Normalized event struct

`%Samen.Billing.ProviderEvent{provider :: atom, event_id :: String.t, kind :: atom,
occurred_at :: DateTime.t, provider_refs :: %{optional(atom) => String.t}, payload :: map}` —
`payload` is ALREADY redacted (§5.4). `kind` is a bounded samen-owned enum the adapter maps
vendor event names onto: `:checkout_completed | :checkout_expired | :subscription_created |
:subscription_updated | :subscription_deleted | :invoice_finalized | :invoice_paid |
:invoice_payment_failed | :payment_method_attached | :payment_method_detached | :unhandled`.
Unknown vendor events map to `:unhandled` and are stored (replay-safe) but not dispatched.

### 3.4 Convergence model (B3 — idempotent, out-of-order safe; T21)

The core `Samen.Billing.Reconciler` implements the fetch-on-event pattern:

1. A verified event names provider object refs; the reconciler calls `fetch_object/3` and
   upserts the mirror from the **authoritative snapshot**, never from the event payload.
2. Idempotency: the `{provider, event_id}` unique key on the replay store (§5.3) makes duplicate
   deliveries no-ops; the upsert itself is idempotent by provider id.
3. Out-of-order convergence: each mirror row stores the provider's object-level
   `provider_updated_at`; a fetch result older than the stored watermark is discarded. Two
   events racing both fetch current truth — either order converges to the same mirror state.
4. Proration (B3): proration line items arrive on the invoice mirror via `fetch_object(:invoice, …)`;
   samen mirrors, never recomputes, provider proration math.

In keyless CI (§7), `fetch_object/3` is served by cassettes/fakes — the reconciler logic is
provider-independent and fully provable hermetically.

### 3.5 Surface-specific rules

- **B5/no-PAN (T23):** card data NEVER transits samen. Payment-method mirror stores display
  metadata only (`brand`, `last4`, `exp_month`, `exp_year` — non-PAN by industry definition);
  a schema probe asserts no PAN-shaped column exists anywhere. `provider_customer_ref` is the
  sole cross-reference to the provider (renamed from the former `stripe_customer_id` under
  T106's INV-4 ratchet 24→0 — see §8.3 note and ADR-038-A); Customer PII stays vaulted
  (spec B5). Adding typed non-PII columns rides the ADR-034 two-party clearance where applicable.
- **B7 dunning (T24):** driven exclusively from `:invoice_payment_failed` normalized events —
  never from polling, never simulated. Retry schedule is mirrored provider truth; the
  grace-period entitlement policy is core logic on the mirror.
- **B4/B6 (T22):** the Invoice mirror gains tax fields + hosted invoice/receipt URLs
  (provider-hosted links surfaced tenant-side; no PDF mirroring).
- **B10 (T26):** the settings page renders the configured flow when `configured?/1` is true and
  the honest "bring your billing" empty state when false — driven by the same predicate, no
  separate flag to drift.

### 3.6 Supersession of `Samen.Scopes.Billing.SyncAdapter`

`SyncAdapter` (+ its always-`{:ok, %{stub: true}}` `Stub`) is superseded. T18 reroutes its
call sites through `Samen.Billing.Provider` and deletes or delegates the old module; the fake
default dies with it. The core test fake (§7.2) replaces `Stub` and is call-recording like it,
but honest: unconfigured fakes refuse.

## 4 · `Samen.Delivery.Provider` (core-defined behaviour)

Module: `samen_core/lib/samen/delivery/provider.ex` (T27). This is the ADR-014 seam
**finalized and renamed**, not a second parallel contract.

### 4.1 Callbacks

```elixir
@callback configured?(config :: map()) :: boolean()

# ADR-014 deliver/2, unchanged semantics. Receipt MUST include :provider_message_id when the
# provider returns one — it is the token-blind join key for deliverability events (§4.4).
@callback deliver(message :: Samen.Delivery.Message.t(), config :: map()) ::
            {:ok, receipt :: map()} | {:error, term()}

# Honest capability declaration; drives the conformance harness (§4.5) and router wiring.
@callback capabilities() :: [:deliverability_webhooks | :inbound | :tracking]

# C4 — bounce/complaint/delivered/open/click, vendor signature scheme in the adapter.
@callback verify_and_parse_event(raw_body :: binary(), headers :: [{String.t(), String.t()}],
            config :: map()) ::
            {:ok, Samen.Delivery.ProviderEvent.t()} |
            {:error, :invalid_signature | :malformed | :not_implemented | term()}

# C5 seam — inbound email. Postmark is the inbound-capable reference; adapters without the
# capability return {:error, :not_implemented} (the honest absence, never a fake parse).
@callback parse_inbound(raw_body :: binary(), headers :: [{String.t(), String.t()}],
            config :: map()) ::
            {:ok, Samen.Delivery.InboundMessage.t()} | {:error, :not_implemented | term()}

@callback redact_payload(payload :: map()) :: map()
```

`use Samen.Delivery.Provider` injects overridable fail-honest defaults for
`capabilities/0` (`[]`), `verify_and_parse_event/3` and `parse_inbound/3`
(`{:error, :not_implemented}`) so minimal adapters stay two-function. **Capability honesty is a
conformance rule:** a declared capability must have a real implementation; an undeclared one
must return `:not_implemented` (both directions tested, §4.5).

### 4.2 Reconciling the existing `Samen.Delivery.Adapter` precedent

`Samen.Delivery.Provider` REPLACES `Samen.Delivery.Adapter` as the one canonical behaviour
(same two core callbacks, same Invariant D1). T27 migrates `LocalSink`, `Smtp`, and `Api` to
`use Samen.Delivery.Provider` (they gain the honest defaults — SMTP has no webhooks and says
so), reroutes `SendWorker`/`Lifecycle.EmailWorker`/`AuthMailer` references, deletes
`Samen.Delivery.Adapter`, and proves it with a grep (zero `Delivery.Adapter` references
survive). All existing Smtp/LocalSink tests stay green — the semantics did not move.

### 4.3 Provider selection

Per-host and per-org selection among the three adapters:
`config :samen_core, :delivery_provider, {module, config}` as the host default, with an
org-level override resolved at the Delivery chokepoint (T27 ships the two-fake selection test).
Misconfig (unknown module, half-configured creds at boot with delivery enabled) raises at boot
per ADR-024. Unconfigured-everywhere remains the honest `:blocked` path of ADR-014 §3.

### 4.4 Deliverability events (C4, T30) — token-blind by construction

`%Samen.Delivery.ProviderEvent{provider, event_id, kind :: :delivered | :bounce | :complaint |
:open | :click | :unhandled, provider_message_id, occurred_at, payload (redacted)}`.

- Recipient matching goes **provider_message_id → send receipt → subscriber ref** — never by
  email address. The raw recipient email in the vendor payload is removed by
  `redact_payload/1` before the envelope persists (§5.4).
- Matched events land as `EmailEvent` rows (new core resource, token-only: send ref, subscriber
  ref, kind, occurred_at) and drive `Suppression` (bounce/complaint → org-scoped suppression via
  the existing ADR-014 chokepoint). Unmatchable events (no receipt for the message id) go to the
  DLQ, operator-visible, token-blind (§5.5).
- Open/click tracking stays default-OFF behind the consent-aware flag (c9); the adapter only
  enables provider-side tracking when the flag says so, and `:open`/`:click` events for
  non-consented orgs are dropped at the handler (asserted both ways in T30).

### 4.5 The shared conformance kit (defined T27/T188; consumed by ALL THREE ESP adapters)

**Current state.** All three ESP adapter packages — `samen_postmark`, `samen_resend` and
`samen_ses` — consume the SHARED CROSS-FAMILY kit `Samen.AdapterConformanceCase`
(`samen_core/lib/samen/adapter_conformance_case.ex`, T188). Their conformance suites are
`samen_postmark/test/conformance_test.exs`, `samen_resend/test/conformance_test.exs` and
`samen_ses/test/conformance_test.exs`. Test infra ships in lib, per the
`Samen.MaskingCase`/`Samen.RedPath` house precedent. Usage:

```elixir
use Samen.AdapterConformanceCase, adapter: SamenPostmark.Provider
use ExUnit.Case, async: true
```

`adapter:` is the only required option, checked at COMPILE time (`Code.ensure_loaded?/1`) —
a missing adapter module raises the named `Samen.AdapterConformanceCase.AdapterNotLoadedError`,
which is how INV-4's "samen_core never depends on an adapter package" stays a provable
optionality rather than a silent one. The kit exposes PLAIN imported assertion functions
(`load_fixtures!/1`, `assert_refusal_table!/1`, `assert_capture_no_leak!/2`,
`assert_redaction!/3`, `assert_masked_segments!/1`) called from explicit `test` blocks, rather
than a macro-generated fixture DSL. Each adapter's `test/fixtures/conformance.exs` is unchanged
across the swap.

The conformance run asserts, for ANY adapter: (a) the unconfigured table — every callback
refuses with `:not_configured`, never `{:ok, _}`; (b) configured `deliver/2` against the
adapter's fixture transport returns a receipt carrying `provider_message_id`; (c) webhook
red/green — a fixture event with a valid signature parses, the same body with a tampered
signature returns `:invalid_signature` and parses NOTHING (plus the positive control,
anti-tautology); (d) redaction — no plaintext email/name survives `redact_payload/1` on the
bounce/complaint fixtures (asserted against the fixture's known PII strings); (e) capability
honesty both directions (§4.1), including the CONFIGURED-but-credential-less refusal, so the
refusal is not a side effect of being unconfigured; (f) the deliver-leak gate (C3/T29) — the
captured outbound ESP payload carries no `vt_` vault token and no forbidden plaintext (INV-1).

**Convergence history — both seams now CLOSED.**
*Seam 1* (`4a2ba48`, A13/T27-owned follow-up): `Samen.Delivery.ProviderConformanceCase`
(`samen_core/lib/samen/delivery/provider_conformance_case.ex`) became a thin SHIM over the
cross-family kit. Its public macro signature and its public function names/arities are FIXED
and unchanged; internally `load_fixtures!/1`, `assert_deliver_no_leak!/2` and
`assert_redaction!/2` now delegate to the kit's `load_fixtures!/1`,
`assert_capture_no_leak!/2` and `assert_redaction!/3` instead of duplicating that logic.
*Seam 2* (adapter-by-adapter adoption): `samen_resend` converged in `423593a` and `samen_ses`
in `6c26f5b`, following `samen_postmark`. Consequently **no adapter package consumes
`ProviderConformanceCase` any more.** Its only remaining consumers are samen_core-internal:
`Samen.Delivery.ProviderConformanceCaseNonVacuityTest`
(`samen_core/test/delivery_provider_conformance_case_test.exs`, which exercises the macro
against a local `ToyProvider`) and `Samen.Delivery.DeliverLeakGateTest`
(`samen_core/test/delivery/deliver_leak_gate_test.exs`, which calls
`assert_deliver_no_leak!/2` as a plain function). `Samen.Delivery.ChokepointAntiBypassProbeTest`
does NOT reference it.

Because the shim's signature never moved, the roadmap-collision rule still holds in its
original form: any change to `ProviderConformanceCase`'s contract is a T27-owned follow-up, not
an in-place edit by an adapter task. What is no longer open is the pair of questions this
section previously left open — whether `ProviderConformanceCase` becomes a shim (it did,
`4a2ba48`) and whether the remaining two ESP adapters converge (they did, `423593a` and
`6c26f5b`).

Adapter split: `samen_postmark` (reference; inbound-capable; serves C5 later),
`samen_ses` (SNS-envelope webhook verification, including the SNS subscription-confirmation
handshake, inside the adapter; no inbound), `samen_resend` (Svix-style signatures; no inbound).
For `samen_postmark` and `samen_resend` the (e) credential-less gap sits on
`verify_and_parse_event/3` (a missing webhook secret). `samen_ses` verifies SNS envelopes by RSA
signature and needs no per-host secret, so its genuine "configured but not wired" gap is
`deliver/2`, which requires an injectable `config[:resolve_recipient]` (ADR-014: no generic ESP
adapter may vault-reveal `to_subscriber_id` to a plaintext email) — its (e) test exercises that
gap instead.

## 5 · Webhook ingress (shared by billing + delivery; T19 builds, T20/T21/T24/T30 consume)

One ingress, two domains. Everything below is the SHARED shape; per-vendor knowledge stays in
the adapters behind `verify_and_parse_event/3`.

### 5.1 Placement + routing

- `samen_web` mounts `POST /webhooks/:provider` (a `samen_webhook_routes` macro, ≈0-LOC vertical
  mount per INV-5) → a raw-body-capturing plug pipeline (signature verification requires the
  raw bytes; the pipeline runs BEFORE `Plug.Parsers` consumes the body) → the ingress
  controller.
- The provider module is resolved from HOST config
  (`config :samen_web, :webhook_providers, %{"stripe" => {SamenStripe.Provider, config}, …}`) —
  runtime dispatch through the behaviour, so `samen_web` (like `samen_core`) compiles with zero
  vendor deps. Unknown `:provider` → 404, nothing logged beyond a counter (fail-closed).

### 5.2 Request lifecycle (binding order)

1. **Rate-limit check** (§6.3) — cheap, before any crypto.
2. **Verify + parse** via the adapter: bad signature / stale timestamp → **400, nothing
   persisted** (T19 red test + control; sabotage patch: removing the verify call flips it).
3. **Persist the envelope** as a `WebhookEvent` row (§5.3) with the REDACTED payload (§5.4).
   Duplicate `{provider, event_id}` → 200 no-op (replay protection; the unique index is the
   arbiter, safe under concurrent duplicate delivery).
4. **Enqueue** the processing job (new Oban queue `webhooks_in`, added next to the existing
   `webhooks_out`) with token-only args — the WebhookEvent row id, nothing else — and return
   200 immediately. Slow work never runs in the request; provider timeouts/retries are handled
   by fast ack + idempotent store.
5. The worker dispatches by domain: billing kinds → `Samen.Billing.Reconciler` (§3.4); delivery
   kinds → the C4 handler (§4.4). Handler failure retries per Oban policy; exhausted/discarded
   → DLQ state (§5.5).

### 5.3 `WebhookEvent` (replay store + DLQ substrate, one resource)

New governed core resource (abbrev via the sanctioned allocator — ADR-023; registry hands-off):
`provider`, `event_id` (unique with provider), `kind`, `occurred_at`, `payload` (redacted map),
`status :: :received | :processing | :processed | :dead`, `attempt_count`, `last_error`
(message + stacktrace digest only — never payload echo), `processed_at`, `org_id` (nilable —
resolved DURING processing; ingress happens before org attribution). Retention: `:processed`
rows pruned after 30 days, `:dead` rows kept until operator resolution (maintenance queue).

### 5.4 PII posture of stored payloads (c10 ruling, INV-1)

Envelopes persist **masked/pruned**: the adapter's `redact_payload/1` strips or replaces the
vendor payload's PII-bearing fields (emails, names, addresses, phone) before the row is
written, keeping provider ids/refs/amounts/timestamps. Redaction is a pure per-adapter function
proven by the conformance harness (§4.5d) and by the billing fixture twin in T19. Replay never
needs the pruned fields: billing replays re-fetch authoritative objects (§3.4); delivery
replays re-match by `provider_message_id` (§4.4). `mix samen.verify.no_pii_columns` covers the
new resource.

### 5.5 DLQ + operator plane (INV-1/INV-2, token-blind)

Oban dead-letter (discarded jobs) flips the envelope to `:dead`; the operator-plane LiveView
lists `:dead` (and recent `:processed`/`:received`) envelopes **token-blind**: provider, kind,
event id, timestamps, attempt count, error summary — no payload rendering beyond the already
redacted map, no vault tokens, no PII columns (INV-2 verifier tiers cover it). Operator actions:
**replay** (re-enqueue the processing job; safe because processing is idempotent) and
**resolve** (mark handled, audited). The view mounts via the operator plane per ADR-010.

## 6 · Rate limiting — BINDING design for T103 (auth) and T19 (ingress)

ADR-037 §5.14 verdicts stand un-reopened: `ash_rate_limiter == 1.0.0` (pinned; the retired
2.0.0 mishap) + Hammer `~> 7.0`, ADOPTED narrow. ADR-035 §4.5 fixes the enforcement shape;
this section unifies the three verifier flags (T01, T98 P3-2, T101) into one design.

### 6.1 Mechanism (restating the binding constraints)

- Deps live in **`samen_web/mix.exs` ONLY** — `samen_core/mix.exs` stays untouched (INV-4
  shape; grep probe in T103).
- **Manual-plug shape** (ADR-035 §4.5): checks are explicit `Samen.Web.RateLimit` calls in
  plugs/LiveView hooks in front of the surfaces. The package's resource-level `rate_limit` DSL
  and Change/Preparation hooks are NOT used (they would compile into core resources).
- ONE shared seam: `Samen.Web.RateLimit` (samen_web) wraps Hammer behind
  `check(surface, key_kind, key_value)` → `:ok | {:error, :rate_limited}`; limits are
  config-tunable (`config :samen_web, Samen.Web.RateLimit, …`); the deterministic Hammer test
  backend + injectable clock keep tests sleep-free. **T103 and T19 both call this module** —
  same limiter, same key discipline, never a parallel implementation.

### 6.2 Keys are non-PII by construction (§5.14 rule, red-tested)

Key format `"{surface}:{kind}:{value}"` where value ∈ {`email_bidx`, credential id, org id,
remote IP} — NEVER plaintext email or any vault-routed value. IP appears only in the limiter's
ephemeral counters (ADR-035 §4.3 posture; not persisted to any resource). T103's probe asserts
no plaintext identifier appears in any Hammer bucket name at runtime; sabotage twin flips it.

### 6.3 Limit table (defaults; config-tunable)

Auth surfaces (T103 wires; restated from ADR-035 §4.5, unchanged):

| Surface | Per-account key | Per-IP key |
|---|---|---|
| Sign-in | 10/min per `email_bidx` | 100/hr per IP |
| Registration | — | 5/hr per IP |
| Token request (verify resend / reset request / invite resend) | 3/15min per `email_bidx` | — |
| Token consume | — | 10/min per IP |
| TOTP 2FA verify | 5/min per credential id | — |

Both key axes are proven independently (IP-rotating attacker still limited per-account;
account-rotating attacker still limited per-IP — T103 red tests). Over-limit → 429/interstitial
with the under-limit positive control; the check must not reintroduce an enumeration timing
signal (parity assertions re-run).

Webhook ingress (T19 wires) — **yes, ingress gets limits**, shaped as backpressure, not loss:

| Surface | Key | Default | Semantics |
|---|---|---|---|
| Ingress flood guard | `"webhook:{provider}"` (per-provider aggregate — providers send from many IPs, per-IP would misfire) | 1000/min | Over-limit → 429. Stripe/Postmark/SNS/Svix all retry on 429 with backoff; events are re-deliverable, so this is honest backpressure with no data loss. |
| Invalid-signature attempts | per IP | 60/min | Counted on verification FAILURE only; once over, 429 before the crypto work — bounds signature-forgery DoS while valid traffic is never charged against it. |

Nothing is ever keyed on payload contents (untrusted pre-verification).

### 6.4 Bounded `login_failed` audit (replaces unbounded rows; T103)

The current per-attempt `auth.login_failed` aud_event row is unbounded under brute force —
exactly what ADR-035 §5's taxonomy row forbade ("failed: bidx-keyed counter only, no PII").
Binding replacement:

- New core resource `Samen.Identity.LoginFailure` (abbrev via allocator): ONE row per
  `email_bidx` (unique index), columns `failure_count`, `window_started_at`, `last_failed_at`.
  Failed attempt → atomic upsert-increment; successful login → reset. No IP, no PII, no
  per-attempt rows.
- `auth.login_failed` aud_events are emitted only on **transition edges**: the first failure of
  a window and each limit-crossing (§6.3 sign-in row), carrying the bidx + a counter snapshot —
  O(edges) audit rows per window instead of O(attempts). T101's per-kind findability test is
  updated to assert the counter + edge events (and stays green).
- Retention: counter rows idle > 30 days pruned by the maintenance queue.
- Red test: N ≫ limit failed attempts produce a bounded row count (the T103 done-criterion 3
  assert), plus the anti-tautology control that the counter genuinely increments.

## 7 · Test posture (rulings M1 + M2, operator re-confirmed 2026-07-22)

### 7.1 Lanes (binding; claim-evidence names which lane ran, per lane honesty in §7.5)

| Lane | Gate | Contents | Network |
|---|---|---|---|
| 0 — hermetic (THE gate) | default; ci.sh / ci-fast.sh | fakes + recorded fixture cassettes + SIGNED-webhook simulator | none, ever (T105 determinism discipline) |
| 1 — Stripe live smoke | `STRIPE_TEST_KEY` set | tagged tests / task against Stripe test mode | Stripe test API |
| 2 — ESP live smoke | `SAMEN_ESP_LIVE=1` + provider creds | real send to a sink address per adapter | live ESP APIs |
| 3 — Postmark no-credential smoke | `SAMEN_POSTMARK_SMOKE=1` (no creds needed) | §7.4 | api.postmarkapp.com |

Lanes 1–3 are NEVER part of the default suites; keyless CI is the gate (M2 confirmed).

### 7.2 Fakes + cassettes

- Each domain ships a call-recording **fake provider in samen_core** (vendor-free, implements
  the full behaviour honestly — unconfigured fakes refuse): `Samen.Billing.FakeProvider`,
  `Samen.Delivery.FakeProvider`. They replace the dishonest `SyncAdapter.Stub` (§3.6) and are
  what core/lifecycle/vertical tests select.
- Adapter packages test against **recorded fixture cassettes**: checked-in JSON request/response
  pairs served by a local transport (no network). Fixture PII is fictional by rule; the refresh
  procedure (re-record against the live lane) is documented per adapter README. Cassettes are
  hand-curated — no auto-record in CI.

### 7.3 The SIGNED-webhook simulator

Signature verification is proven for real, not stubbed: a test helper (`samen_stripe` test
support for billing; built into the conformance harness for ESPs, §4.5c) constructs the
provider-correct signature header (e.g. Stripe's `t=…,v1=HMAC-SHA256` scheme) over fixture
payloads with a KNOWN test secret and POSTs through the REAL ingress pipeline (§5.2). Red
(tampered body/signature/stale timestamp → 400, nothing persisted) and green (valid → stored,
processed) both run in lane 0. This is what lets keyless CI honestly claim the verification
code path.

### 7.4 NEW — the Postmark `POSTMARK_API_TEST` lane (operator enrichment; T27 owns)

Postmark's real API accepts the public literal server token `POSTMARK_API_TEST`: requests
validate and return success, and nothing is delivered. Binding design:

- Shipped as `mix samen.smoke.postmark` inside `samen_postmark` — a task, NOT an ExUnit test in
  the default suite (default suites stay network-free, lane 0).
- Gated by **`SAMEN_POSTMARK_SMOKE=1`**; requires no credential.
- Three terminal states, printed and exit-coded: `POSTMARK-SMOKE: PASSED` (real HTTP round-trip
  to api.postmarkapp.com succeeded, exit 0) · `POSTMARK-SMOKE: SKIPPED (offline: <reason>)`
  (connect/DNS failure detected — exit 0 with the SKIPPED line; an honest skip, NEVER reported
  as passed) · `POSTMARK-SMOKE: FAILED` (API reachable but the adapter's request/parse is wrong
  — exit 1). Claim-evidence records the printed state verbatim; a SKIPPED run may not be
  claimed as coverage.
- Phase gates (T31 onward) SHOULD run it and record the state; it never gates ci.sh/ci-fast.sh,
  so an offline machine cannot flake the suites.

### 7.5 What each lane may honestly claim (claim-evidence discipline, INV-6)

- Lane 0 claims: adapter request/response logic against recorded vendor shapes; the FULL
  signature-verification path (via §7.3); reconciler convergence; fail-honest tables;
  redaction. It may NOT claim "sends real email" or "moves real money".
- Lane 3 additionally claims: real-HTTP reachability + request acceptance by Postmark's live
  API (auth, serialization, endpoint) — still not delivery.
- Lanes 1/2 claim actual provider round-trips (test-mode charge objects; a landed sink email).
- Every gate's claim-evidence entry states which lanes ran (M2 ruling text).

## 8 · Package topology (INV-4) + the T31 probe

### 8.1 Four first-party-but-separate packages

Repo root gains `samen_stripe/`, `samen_postmark/`, `samen_ses/`, `samen_resend/` — standalone
mix projects (the spikes/verticals pattern), each: path-dep on **`samen_core` only** (never
`samen_web`); its own test suite including the conformance harness; wired into the `ci.sh` app
list by its owning task (T18/T27/T94/T95). `samen_core` and `samen_web` gain ZERO vendor deps —
core defines behaviours + fakes + resources; web dispatches to host-configured modules (§5.1).

### 8.2 HTTP clients live in the adapters

House HTTP client for adapter packages: `{:req, "~> 0.5"}`, declared per adapter package.
`samen_ses` may additionally carry an AWS SigV4 signing dep (its own package, allowed — vendor
deps live in adapter packages by definition). Neither `samen_core/mix.exs` nor
`samen_web/mix.exs` gains any HTTP client from this work (samen_web's pre-existing optional
assent/req story is untouched).

### 8.3 Vendor-string grep probes (precision matters)

- `samen_core/lib` + `samen_core/mix.exs`: zero case-insensitive `stripe`, `postmark`,
  `postmarkapp`, `amazonaws` occurrences.
  - **§8.3-vs-§3.5 reconciliation (T106):** §3.5 formerly sanctioned `stripe_customer_id`
    as the cross-reference attribute, which lived in `samen_core/lib` (the billing
    blueprint) and thus stood in tension with §8.3's strict zero-`stripe` rule — carried
    as the ONE documented ratcheted carve-out (baseline 24). T106 renamed every billing
    external-reference attribute to the vendor-neutral `provider_<object>_ref` shape,
    driving the carve-out to ZERO. The tension is CLOSED: §3.5's sanctioned cross-ref is
    now `provider_customer_ref`, so §8.3 admits NO exception and
    `test/billing_vendor_free_test.exs` asserts a strict zero with no carve-out.
- **Resend + SES need scoped probes** — "resend" is a legitimate core word (resend
  verification email; ADR-035 token requests) and "ses" collides as a substring: probe for the
  `Resend` module prefix (`grep -w 'Resend\.'` / `SamenResend`), the `:resend` mix dep atom,
  and `SamenSes`/`aws`/`amazonses` — NOT the bare words. T94/T95 encode exactly these.

### 8.4 The T31 INV-4 probe (binding specification)

At the phase-2 gate: (1) move ALL FOUR adapter dirs out of the tree (e.g. `mv` to a scratch
dir); (2) `cd samen_core && mix test` AND `cd samen_web && mix test` both green — core claims
hold with every adapter absent; delivery falls back to the honest `:blocked`/`:not_configured`
paths, billing settings render the empty state; (3) run the §8.3 greps; (4) restore the dirs
byte-exact (SHA-256 check, the sabotage-harness restore discipline). Only then run the full
`./ci.sh` with everything present.

## 9 · Consumer map (which sections bind each task)

| Task | Bound by |
|---|---|
| T18 (B1 skeleton) | §3.1–§3.2 callbacks + fail-honest table, §3.6 SyncAdapter supersession, §8.1–§8.3 topology/probes |
| T19 (B9 ingress) | §5 all (lifecycle order §5.2, WebhookEvent §5.3, redaction twin §5.4, DLQ/operator view §5.5), §6.1–§6.3 ingress rows |
| T20 (B2 checkout) | §3.1 `create_checkout_session`, §3.3 kinds, §3.4 reconcile-on-`:checkout_completed`, §7.3 simulator |
| T21 (B3 lifecycle sync) | §3.4 convergence model (fetch-on-event, watermark, idempotency), §3.1 `fetch_object`/`change_subscription` |
| T22 (B4+B6 invoices/tax) | §3.5 B4/B6 rule, §3.4 invoice mirror via fetch |
| T23 (B5 payment methods) | §3.5 no-PAN rule, §3.1 `create_portal_session` |
| T24 (B7 dunning) | §3.5 B7 rule (webhook-driven only), §3.3 `:invoice_payment_failed` |
| T25 (B8 usage) | §3.1 `report_usage` + idempotency-key rule |
| T26 (B10 settings) | §3.5 B10 rule (`configured?/1`-driven honest empty state) |
| T27 (C1 behaviour+harness+postmark) | §4 all (esp. §4.2 rename/migration, §4.5 harness contents), §7.2, §7.4 (owns the smoke task), §8 |
| T28 (C2 outbound) | §4.3 selection, §4.1 receipt rule, ADR-014 §3 semantics (unchanged), §7.2 fakes |
| T29 (C3 PII-safe rendering) | §4.1 `Message` token-only envelope (ADR-014), INV-1 masking discipline (MaskingCase 3-proof) |
| T30 (C4+C8 deliverability+digest) | §4.4 all (message-id matching, EmailEvent, suppression, c9 consent flag), §5.2 lifecycle, c11 digest default |
| T94 (samen_ses) | §4.5 harness READ-ONLY, §4.1 SNS notes (§4.5 adapter split), §8.2–§8.3 scoped probes |
| T95 (samen_resend) | §4.5 harness READ-ONLY, §8.2–§8.3 scoped `Resend` probes |
| T103 (rate limiting + bounded audit) | §6 all — §6.1 mechanism, §6.2 keys, §6.3 auth rows, §6.4 counter shape |

## 10 · Consequences, red paths, revisit triggers

- **+** One ingress, one limiter seam, one conformance harness — B and C tracks share
  infrastructure instead of growing parallel ones; sonnet implementers have full callback
  signatures and never re-litigate shape.
- **+** Every seam stays fail-honest: unconfigured refuses, undeclared capability refuses,
  offline smoke skips honestly, keyless CI claims only what it proves.
- **−** The fetch-on-event convergence model costs one provider API call per webhook in live
  operation (deliberate: correctness over chatter; Stripe's own recommended pattern).
- **−** `SyncAdapter` consumers see a breaking change in T18 (intended — the fake-`:ok` stub is
  the lie this ADR exists to remove).
- Sabotage duties: T19 (signature check removal flips the named test — handoff criterion 4),
  T103 (limiter-key composition + bounded-counter twins), T27 (conformance red/green twin).
- **Revisit trigger carried from ADR-037 §5.12:** if a wallet/credits/prepaid-balance feature
  becomes a requirement, ash_double_entry + the §5.2 money stack is the designated shape — a
  future ADR extends `Samen.Billing.Provider`, it does not fork it.
- Re-evaluation: if a fourth ESP or a second billing provider is requested, it enters via the
  same behaviours + harness; the harness (not this ADR) is the conformance authority from then
  on.
