# ADR-042 — LiveView client adoption + the progressive-enhancement contract (operator ruling R1a)

- **Status:** Accepted (design; T113 implements; T117 must land first).
- **Date:** 2026-07-27
- **Task:** T112 — the ADR half of the WS-UX dogfood-sweep R1 fork
  (`_orch/ux/dogfood-report.md` §3b R1). T113 is the substrate build; per the standing
  decompose-cross-cutting-changes rule this ADR is doc-only.
- **Deciders:** the operator (Chris, ruling of 2026-07-27: **wire the LiveView JS
  client** — R1 exit (a), with the hybrid's auth-spine fallback made binding), recorded
  by fable, grounded in dogfood finding B1 and the 11-persona sweep.
- **Supersedes / amends:**
  - **ADR-030** — *amended, not replaced.* ADR-030's responsive decisions (two
    breakpoints, drawer sidebar, table restack, skeleton primitive) all stand. What this
    ADR supersedes is its framing clause: "no new JS framework" / "Kit-and-CSS-only …
    zero risk to vertical logic or the masking spine" is no longer the platform's
    *interactivity* posture. The masking-spine claim survives on its true ground (§6
    here): the invariant lives in the value layer, not in the absence of JavaScript.
  - **`docs/ws-e/design.md` §1.5** and **`docs/ws-e/build-plan.md` E6-P2** — the
    "samen_web asset pipeline is CSS-only (no esbuild, so no LiveView JS hook)" posture.
    E6-P2 explicitly recorded "a host that later adds a real … bundle can move this to a
    `phx-hook` — an available upgrade, not required." **This ADR takes that upgrade**
    (as a plain `app.js` listener, not a hook — §4 C2).
  - The `Samen.Web.Layouts` `@moduledoc` claim "No asset pipeline — a real deploy would
    add esbuild/tailwind in the host app, not here" — now false in both halves: the
    pipeline lands in samen_web, and it is not esbuild (§3).

---

## 1 · Context — what the dogfood sweep proved

The platform ships **zero client JavaScript**: `Samen.Web.Layouts.root/1` emits one CSS
link (`samen_ui.css`) and an inline nonce'd ⌘K listener; there is no LiveSocket, no
app.js — by design. The consequence (dogfood B1, seen by 5+ personas): **every
`phx-click`/`phx-submit` write affordance is browser-dead on every host** — driftwood
dispatch, pawchart new-contact, CRUD, DLQ replay, notification mark-read, the flag
modal, new-plan — tenant plane and operator plane alike. Server-side LiveView tests
simulate the socket, so CI stayed green while a human could read everything and write
nothing beyond the five controller-POST forms T110 added. The worst single symptom was
S1: the JS-less `/signup` degraded a `phx-submit`-only form to a native **GET**,
leaking the plaintext password into the URL (fixed by T110's controller-POST arc).

The write layer was built as LiveView handlers **assuming a client that was never
shipped**. Two coherent exits existed (R1): (a) wire the client; (b) extend T110's
controller-POST pattern platform-wide. Exit (b) preserves the posture but demands a
POST-route/form twin for every interactive surface ever shipped, and structurally
blocks the upcoming ADR-039 automation UI (T39/T42), the ADR-040/041 object UI
(T43–T48), and WS-G views — kanban drag-and-drop (T51), clone affordances (T57), chat
(C6/C7). The operator ruled for (a).

**The decisive implementation fact** (grep-verified during this ADR): the server half
of LiveSocket has been wired all along. Every browser host — driftwood
(`endpoint.ex:21`), pawchart (`endpoint.ex:21`), and the generated-app template
(`endpoint_ex.eex:19`) — already declares
`socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: …]])`,
and `config_exs_web.eex` already sets the `live_view: [signing_salt: …]`. There is no
`assets/` directory and no esbuild/tailwind/node dep anywhere in the repo. What is
missing is exactly: a client bundle, an `app.js` that connects it, and the static-serve
plumbing.

### What is gained, what is lost, how the loss is bounded

**Gained:** every existing `phx-click`/`phx-submit` handler across samen_web + both
verticals + every generated app becomes browser-real at near-zero per-surface cost; the
Phase-3+ UI roadmap (automation, approvals, objects, views, chat) builds on the
framework's native interaction model instead of a controller-twin tax on every verb;
LiveView's own PE machinery (dead render, `phx-trigger-action`) starts actually working.

**Lost:** the strict "the product works with JavaScript disabled" guarantee, and the
"zero client-code surface" simplicity claim.

**Bounded how:** (1) the auth/first-run/recovery spine keeps a binding no-JS
controller-POST baseline (§4 C5 — a user with broken JS can still sign up, get in, and
recover the account); (2) all reads keep working JS-off (a LiveView dead render is
real server HTML); (3) no node/npm/bundler toolchain is added — the entire client is
three static files served from deps that are already in the lockfile (§3), so "zero
asset *pipeline*" remains true even though "zero client JS" does not; (4) masking
remains server-rendered — the client gains no resolution capability (§6).

## 2 · Decision

**Ship the Phoenix LiveView JS client platform-wide through the shared samen_web root
layout, with no node toolchain, under a binding progressive-enhancement contract for
the auth spine.** Five load-bearing decisions:

1. **The client is wired once, in `Samen.Web.Layouts.root/1`, and inherited
   everywhere.** Verticals and generated apps get it through the existing
   `use Samen.Web.Layouts` seam at zero authored LOC — the same framework-first
   mechanics as `samen_ui.css` (ADR-009, ADR-022). No per-vertical, per-page, or
   per-LiveView change is in scope.

2. **Asset pipeline: vendored prebuilt bundles + a hand-authored static `app.js` — no
   esbuild, no npm, no `assets/` build step** (§3 for the full ruling and the recorded
   esbuild trigger).

3. **Progressive-enhancement contract: two surface classes** (§5). Class A (the
   auth/first-run/recovery spine) MUST keep working with JS off — the T110
   controller-POST routes are the binding baseline; the client enhances in place.
   Class B (all authenticated product surfaces) MUST keep server-rendered reads JS-off;
   writes MAY require the socket.

4. **The masking law is untouched by construction** (§6): all values are resolved
   through `Samen.Api.PiiResolution` on the actor's plane server-side before any HTML
   — initial render or LiveView diff — crosses the wire; `%Masked{}` renders `••••`
   server-side; the client never resolves, upgrades, or unmasks anything. INV-1 holds
   unchanged; no masking watch-list assertion may be loosened.

5. **Ordering: T113 lands only after T117.** The client makes existing operator-plane
   write handlers browser-real; T117's finding (generated `/operator/*` ships with no
   prod authn gate) means activating writes first would worsen a latent exposure into a
   live one. T113 is `blocked_by: [T112, T117]` and stays that way.

**Explicit non-decision (scope guard):** the CSS-only *design system* is unchanged.
`samen_ui.css`, the `:root` tokens, and the `Samen.UI` function-component kit
(ADR-008/009) remain exactly as shipped; ADR-030's responsive CSS remains exactly as
shipped. This ADR reverses the interactivity posture (no-JS → LiveSocket), **not** the
visual/component system. Any T113 diff that rewrites kit components, adds a JS UI
framework, or converts server-rendered markup to client-rendered markup exceeds this
ADR.

## 3 · Asset-pipeline ruling — the no-node path

**Rejected: esbuild** (the Phoenix-house default). It would introduce node + a package
lockfile + a build step into a repo and CI that today have none; every host and every
generated app would need `assets/` scaffolding, `mix esbuild` config, and a
`package.json` the operator must keep patched; and it buys nothing today — samen
authors no npm dependencies and no importable client modules.

**Adopted: the documented no-build path.** Both `phoenix` and `phoenix_live_view`
already ship prebuilt browser IIFE bundles in their own `priv/static/`
(`phoenix.min.js` → global `Phoenix`; `phoenix_live_view.min.js` → global `LiveView`)
— verified present in this repo's deps for samen_web, driftwood, pawchart, and demo.
The client therefore ships as **three static files, zero build steps**:

| file | served from | contents |
|---|---|---|
| `/assets/phoenix.min.js` | `{:phoenix, "priv/static"}` (dep-owned) | Phoenix.Socket |
| `/assets/phoenix_live_view.min.js` | `{:phoenix_live_view, "priv/static"}` (dep-owned) | LiveSocket |
| `/assets/app.js` | `{:samen_web, "priv/static/assets"}` — next to `samen_ui.css` | ~30 hand-authored lines: read the CSRF meta, `new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token}})`, `connect()`, expose `window.liveSocket`; plus the relocated ⌘K listener (§4 C2) |

Serving the framework bundles **from the deps' own priv** (never copied into samen_web)
makes client/server version skew structurally impossible: the JS a host serves is by
construction the JS its resolved `phoenix_live_view` version shipped. Each host
endpoint widens its existing scoped `Plug.Static` posture (today
`only: ~w(samen_ui.css)`) with the two dep sources and `app.js` — a bounded, enumerable
edit to the two hand-authored endpoints + the endpoint templates (the endpoint stays a
thin emitted file per ADR-022; the layout, which is inherited, carries the script tags).

**Ownership:** the pipeline is **samen_web-owned** (app.js lives in samen_web's priv,
script tags live in the shared layout) with a **thin emitted seam** (three `Plug.Static`
clauses in each host endpoint). Nothing is vendored per host.

**Recorded trigger for revisiting (ADR-033 style):** if a future surface genuinely
requires an npm dependency or module bundling — e.g. a WS-G drag-and-drop library that
cannot be hand-rolled as a plain hook, or client code exceeding what hand-authored
static files can honestly carry — THAT task files an ADR adopting esbuild. Until the
trigger fires, adding node to this repo is out of bounds.

## 4 · Binding contracts for T113 (implement verbatim; each is testable)

- **C1 — Script tags in the shared root layout.** `Samen.Web.Layouts.root/1` emits, in
  `<head>`, exactly three `defer` script tags in this order — `phoenix.min.js`,
  `phoenix_live_view.min.js`, `app.js` — each carrying the existing
  `nonce={assigns[:csp_nonce]}` seam. Every host inherits them with zero authored LOC.
- **C2 — `app.js` is dependency-free and total-behavior-enumerable.** It (a) reads the
  `csrf-token` meta, (b) constructs
  `new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: …}})`,
  (c) `connect()`s, (d) exposes `window.liveSocket` (reconnect/debug) and an initially
  empty `window.SamenHooks` registry (the seam future kit hooks register into), and
  (e) absorbs the ⌘K listener currently inlined in the layout — the inline `<script>`
  block is deleted (taking E6-P2's recorded upgrade). No other behavior. Websocket
  transport only (matching the endpoints' declaration; no longpoll).
- **C3 — Static serving.** samen_web's endpoint posture, driftwood's and pawchart's
  endpoints, and the generated endpoint templates (`endpoint_ex.eex`; the web-bearing
  flavors of `api_endpoint_ex.eex` if they serve the browser UI) each serve the three
  files via scoped `Plug.Static` (`only:` allowlists — no directory-wide exposure,
  preserving the "cannot shadow any app route" property). demo is API-only
  (`Plug.Router`, no browser pipeline, does not use the layout) and is untouched.
- **C4 — gen.app parity, zero hand-edit.** A freshly generated app serves all three
  files and connects the socket with no manual step. Template changes are confined to
  the endpoint templates (per C3 — the layout is inherited, not emitted);
  `samen_core/test/fixtures/templates_golden/*` is updated in the same commit,
  byte-exact, and the three `ci.sh` gen probes stay green (registry snapshot/restore
  discipline unchanged; `priv/abbrev_registry.json` untouched).
- **C5 — The Class-A no-JS baseline is a regression boundary.** The T110 surfaces —
  `/signup`, `/reset`, `/reset/:token`, `/invite/:token` (`AccountController`), the A8
  onboarding wizard (`WizardController`), 2FA/TOTP enroll (`TotpEnrollController`), and
  the pre-existing `LoginLive`/`SessionController` pair — keep their real
  `action=… method="post"` form attributes and their paired `post(…)` router routes.
  T113 deletes none of them, and `account_controller_test.exs` (including its positive
  control that flags the pre-fix shape) passes unmodified. These forms become
  *enhanced-in-place*: with the socket connected, LiveView validation +
  `phx-trigger-action` run as designed; with JS off, the native POST submits to the
  controller exactly as T110 shipped it.
- **C6 — Masking stays server-resolved; the watch-list stays green unmodified.** No
  masking test file's assertions are loosened, no new client-side code path touches a
  vault value or a `vt_*` token, and the source-scope claim of build-plan E6-P1 extends
  to `app.js`: it contains no `Vault.`/token-unwrap/PII-field reference (it is a
  transport shim + focus listener, nothing more).
- **C7 — CSP/CSRF posture.** `protect_from_forgery` pipelines are unchanged; the
  LiveSocket authenticates with the same CSRF token via connect params (C2). All three
  script tags ride the existing `csp_nonce` seam (C1) — today no host emits a CSP
  header, so the attribute stays dormant-but-ready exactly as the ⌘K script's nonce is
  now; T113 documents (README or endpoint comment) that a host enabling CSP needs
  `script-src` nonce'd and `connect-src` covering `wss:`/`ws:` self for `/live`.
- **C8 — Browser-provable acceptance (both directions), evidenced like T110's
  `work/browser-proof.md`:**
  1. *JS on:* a representative previously-dead `phx-click` write from the B1 list
     (e.g. notification mark-read, or driftwood dispatch) **mutates persisted state and
     re-renders** in a real headless browser — not a LiveViewTest simulation.
  2. *JS off:* with scripts disabled, the signup→login arc completes via the
     controller-POST path with no credential in any URL (repeat T110's probe).
  3. A generated scratch app proves the same two, confirming C4.
- **C9 — Adversarial gate (house sabotage discipline).** T113 ships at least one
  sabotage patch under `scripts/sabotages/` — removing the LiveSocket wiring from the
  layout (or app.js from the allowlist) must flip a NAMED test that asserts the three
  script tags / asset availability, then revert byte-exact. This makes "the client is
  actually shipped" refutable, closing the exact CI-green-while-browser-dead gap B1
  exposed.
- **C10 — Doc truth.** The now-false posture statements are updated in the same change:
  the `Samen.Web.Layouts` `@moduledoc` ("No asset pipeline …"), and pointer notes on
  ws-e design §1.5 / build-plan E6-P2 referencing this ADR. `docs/adr/README.md`
  carries the ADR-042 row (done by T112).
- **C11 — Ordering.** T113 starts only after T117's verdict is a green landing (§2.5).
- **C12 — Scope guard.** The T113 diff touches: the shared layout, `app.js` (new), host
  endpoints, endpoint templates + golden fixtures, the named tests/sabotage, and the C10
  docs — nothing else. No kit-component rewrites, no per-page LiveView conversions, no
  controller-POST twins added or removed (structural check on the diff's file list,
  same convention as ADR-030 RP-RE-3 / ADR-041 §7).

## 5 · The progressive-enhancement contract (general rule, beyond T113)

- **Class A — no-JS-REQUIRED (binding):** every unauthenticated, first-run, or
  account-recovery surface: signup, login/logout, email verify, password-reset
  request + reset, invite accept, onboarding wizard, 2FA/TOTP enroll and challenge.
  These MUST complete with JavaScript disabled via real controller-POST routes
  (credentials in the body, never the URL). Rationale: these are the surfaces a user
  with broken/blocked JS must still be able to traverse to get in and recover access,
  they are the platform's most security-sensitive forms (S1 was exactly here), and
  T110 already paid for the pattern. They SHOULD also be enhanced-in-place (C5) — the
  fallback is a floor, not the experience. **Any future surface in this class ships its
  controller-POST fallback with its first version** — this is the rule that keeps the
  loss of the no-JS guarantee bounded, permanently.
- **Class B — JS-ENHANCED (default for everything else):** all authenticated product
  surfaces (CRUD, dispatch, DLQ replay, mark-read, flags, settings edits, upcoming
  automation/approval/object/view/chat UI). Reads MUST remain real server-rendered HTML
  with JS off (LiveView's dead render provides this for free — do not break it with
  client-only rendering). Write affordances MAY require the connected socket; no
  controller-POST twin is required or wanted (that was R1 exit (b), declined).
  `phx-submit` forms in this class degrade to LiveView's native behavior; a
  `<noscript>` notice in the shared layout ("interactive features require JavaScript;
  sign-in works without it") is a RECOMMENDED courtesy, not a contract.
- **Class assignment default:** unauthenticated/recovery ⇒ A; everything else ⇒ B;
  reclassifying a surface OUT of Class A requires an ADR amendment, not a task-level
  call.

## 6 · Security / masking analysis

- **INV-1 (mask-by-default across planes) is unaffected by construction.** LiveView's
  wire protocol carries server-rendered template parts; every value in an initial
  render or a diff has already passed through `Samen.Api.PiiResolution` on the actor's
  plane, where `%Masked{}` renders `••••`. The client is a DOM patcher — it possesses
  no token, no key, no resolution API, and `app.js` contains no code path that could
  acquire one (C6). The dogfood's P5/P3/P7/P11 verdict ("the masking law held clean")
  was earned server-side and is not re-opened by shipping a transport.
- **New surface honestly named:** the socket makes *writes* real, which makes the
  T117 gating defect meaningful — an ungated operator console goes from read-only-
  exposed to write-exposed. Hence C11's hard ordering. Similarly, S4 (per-write audit,
  bound to T38) becomes more urgent once writes are live; that binding stands.
- **Reveal-window residue** (dogfood R2: expired plaintext lingering in an open socket
  until re-mount) is a pre-existing LiveView-session property that becomes *observable*
  once the client ships; it is bound to R8/T35, not to T113 — recorded here so it is
  not lost.
- **CSRF/CSP:** unchanged pipelines; token-authenticated socket; nonce-ready script
  tags (C7). The client introduces no inline eval, no external CDN, no third-party
  origin.

## 7 · Consequences

**Positive** — every already-written write handler on every host becomes real from one
inherited layout change + three static files; the Phase-3+ UI roadmap (T39/T42,
T43–T48, T50–T58, C6/C7) is unblocked on its native interaction model; no node/npm
toolchain enters the repo or CI; version skew between client and server is structurally
impossible; the auth spine keeps a tested no-JS floor.

**Negative / accepted** — the strict no-JS product guarantee is gone (bounded per §1);
a real browser-JS surface now exists and must be reasoned about in security reviews
(bounded: ~30 auditable lines + two framework bundles); hand-authored client code has
no bundler/minifier (accepted until the recorded esbuild trigger fires); T49's re-walk
must re-run every persona's write-verb probes (dogfood §5 — the single change that
flips the most findings at once).

**Neutral** — kit and CSS untouched; demo untouched; controller-POST auth routes
untouched; the ⌘K listener relocates from an inline block to app.js with identical
behavior.

## 8 · Red paths / verification

- **RP-JS-1 (client actually ships):** C9's sabotage — layout stripped of the wiring
  flips a named test, reverts byte-exact.
- **RP-JS-2 (no-JS auth floor):** C8.2 — scripts-disabled signup→login completes,
  no credential in any URL; `account_controller_test.exs` unmodified-green is the
  standing regression tripwire.
- **RP-JS-3 (masking under the socket):** the masking watch-list suites pass
  unmodified; T49's P5 grep sweep re-runs over socket-rendered DOM on the new client
  (no `vt_*`, no plaintext) — the first browser-real masking walk WITH the client.
- **RP-JS-4 (gen parity):** ci.sh gen probes green; golden fixtures byte-exact; a fresh
  scratch app passes C8.3.
- **RP-JS-5 (scope guard):** C12's structural file-list check on the T113 diff.
