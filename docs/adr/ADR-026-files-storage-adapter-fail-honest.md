# ADR-026 — Files engine: fail-honest storage adapter behaviour, quarantine-by-default, LiveView upload chokepoint

- **Status:** Accepted (design; WS-E phase E2 implements).
- **Date:** 2026-07-16
- **Task:** WS-E / G14 — the `File` resource (`pfl`: filename, content_type, size_bytes, storage_key, status, search_vector) is a metadata record; `storage_key` is a bare string the host populates by hand. NO upload action, NO storage adapter, NO preview. Build the real engine: an adapter behaviour + local impl, a LiveView upload chokepoint, size/type enforcement, and a preview surface — framework-first so both verticals inherit at ≈0 LOC.
- **Deciders:** opus (WS-E design), grounded in `docs/gap-discovery/end-user.md` G6 + `docs/gap-discovery/harden-existing.md` H-10 (files are "scaffolds, not services"), the shipped `Samen.Delivery.Adapter` fail-honest precedent (ADR-014), and the live `File` blueprint.

---

## 1 · Context

`File` (`samen_core/lib/samen/scopes/primitives/blueprint.ex`) stores metadata only. A host must upload the bytes elsewhere and paste the resulting `storage_key` into a create action by hand — the exact "reads as batteries-included, is convention-only" trap H-10 names. There is no `@callback upload`, no `Phoenix.LiveView.allow_upload`, no size/type limit, no preview render. The kernel already has FOUR adapter-behaviour precedents to mirror (`Samen.Delivery.Adapter`, `Billing.SyncAdapter`, `Webhook.HttpAdapter`, `Samen.Anchor`), all of which share one house rule: **the adapter is fail-honest — a stub NEVER returns `{:ok, _}` for a no-op**, and `configured?/1` reports honestly whether real backing exists.

The question is four-fold: (a) where the storage abstraction lives and what its contract is; (b) how uploads route so bytes never bypass governance; (c) what the default security posture of a freshly-uploaded file is; (d) whether file **preview** is a new PII render surface (it is — filenames and bodies can be PII).

## 2 · Decision

**Five load-bearing decisions:**

1. **A `Samen.Files.Storage` behaviour in `samen_core` (web-dep-free), fail-honest, with a `Local` impl as the CI/dev default and an `S3` skeleton.** Callbacks: `configured?/1`, `put(key, binary, opts) :: {:ok, meta} | {:error, reason}`, `get(key, opts) :: {:ok, binary} | {:error, reason}`, `delete(key, opts) :: :ok | {:error, reason}`, `presign_get(key, opts) :: {:ok, url} | {:error, :not_configured}`. Mirrors `Samen.Delivery.Adapter` exactly: `Local` writes to a config'd dir (real, works in CI); `S3` is a skeleton whose `configured?/1` returns false absent creds and whose `put/3` returns `{:error, :not_configured}` (NEVER `{:ok}`) — the S3 wiring stays an **operator-TODO** (no `ex_aws`/`req` dep is added; `presign_get` on `Local` returns a framework-served `/files/:id` route, on `S3` a real presigned URL once creds exist). The adapter is selected by config; verticals inherit at 0 LOC.

2. **Upload routes through a single kernel chokepoint, `Samen.Files.upload/3`, which is the ONLY create path.** `upload(scope, %{filename, content_type, binary}, opts)` (a) enforces size/type limits from bounded config BEFORE touching storage, (b) calls `Storage.put/3`, (c) creates the `File` row via the governed Ash create action (org-scoped, member+ policy) with the returned `storage_key`, (d) writes the existing `file_uploaded/3` audit event. LiveView uses `allow_upload` + `consume_uploaded_entry` and hands the consumed binary to `Samen.Files.upload/3` — the LiveView never writes a `storage_key` directly. This makes "no ungoverned file row" true by construction: a `storage_key` cannot appear on a row without having passed size/type + policy + audit.

3. **Quarantine-by-default is fail-CLOSED.** A newly uploaded file is created with `status: :quarantined`, not `:active`. Preview/download of a `:quarantined` file is REFUSED. Promotion to `:active` requires a scan pass — but since no real AV scanner ships in WS-E, the framework provides a `Samen.Files.Scanner` behaviour with a `Noop` impl that must be **explicitly** configured to auto-promote (an operator opt-in, honestly logged), and a `Reject` default that leaves files quarantined until a real scanner is wired. The default posture is: unscanned ⇒ quarantined ⇒ not previewable. This is the fail-closed analog of the delivery no-op: the framework does not pretend a file is clean.

4. **File preview is a NEW PII render surface and ships per-plane masking tests.** `filename` is host-vaultable (a filename can be PII: `patient-jane-doe-xray.png`) and file BODIES can be PII. The preview LiveView renders the filename through `Samen.Api.PiiResolution` (operator-without-grant sees `••••`, same as the notification-inbox precedent), and byte download/`presign_get` is **plane-gated**: the operator plane cannot pull a tenant's raw bytes without a reveal grant — the request is refused, not masked (bytes have no `Masked` representation). Red-path: an operator-plane preview request for a vaulted filename must render masked; an operator-plane download must be refused; sabotaging the plane check FAILS the test.

5. **Type/size limits are bounded config, enforced at the chokepoint, fail-closed on unknown.** `config :samen_core, Samen.Files, max_bytes:, allowed_content_types:` — an upload whose `content_type` is not in the allowlist or whose size exceeds `max_bytes` is refused BEFORE `Storage.put`. Allowlist-by-default: an empty/unknown content_type is refused, never silently stored.

## 3 · Rationale

- **Behaviour + Local-default + S3-skeleton** matches the four shipped adapter precedents and the standing "real deploy is operator-TODO" carry: WS-E ships a working (Local) engine + an honest (S3) skeleton, never a live-S3 claim.
- **Single `upload/3` chokepoint** is the files analog of the vault write chokepoint — it makes "governed by construction" a structural fact, not a convention a host must remember.
- **Quarantine-by-default** is the framework's fail-closed posture applied to a new surface: the system never asserts a file is safe it hasn't scanned; the honest default is "held," and auto-promote is an explicit, logged opt-in.
- **Preview through PiiResolution + plane-gated bytes** closes the "file preview + filename render" entry on the six-surface masking watch-list; bytes are refused (not masked) because there is no partial-reveal of a binary.

## 4 · Consequences

**Positive** — a real upload→store→quarantine→preview lifecycle every vertical inherits at 0 LOC; the S3 path is a named operator-TODO not a lie; the masking watch-list surface is closed with red-paths; the `search_vector` on `File` becomes populatable (feeds ADR-027 search).

**Negative / accepted** — no real AV scanning ships (Scanner is a behaviour + Noop/Reject; a real ClamAV/S3-scan impl is operator-TODO, honestly). `Local` storage is single-node (fine for dev/CI/single-Fly-machine; multi-node needs the S3 impl). `presign_get` on `Local` serves bytes through the app (acceptable at dev scale).

**Neutral** — new `Samen.Files` module + two behaviours (`Storage`, `Scanner`) + `Local`/`S3`/`Noop`/`Reject` impls; a `/files/:id` framework route (byte-serve, plane-gated) mounted by a new `samen_files_routes` router macro; `File.status` default flips `:active → :quarantined` (a data-model default change, migration-free).

## 5 · Red paths

- **RP-FI-1 (AC-G14-2) governed-by-construction:** a `File` row cannot be created with a `storage_key` except through `Samen.Files.upload/3`; a direct `Ash.create` bypassing the chokepoint is refused by policy/guard. Sabotaging the chokepoint (allowing a raw create) FAILS the test.
- **RP-FI-3 (AC-G14-4) quarantine fail-closed:** a freshly uploaded file is `:quarantined` and preview/download is refused; configuring `Scanner.Noop` promotes it; the default `Reject` leaves it held. Defaulting a new file to `:active` FAILS the fail-closed test.
- **RP-FI-4 (AC-G14-5) preview masking + byte gate:** operator-plane preview of a vaulted filename renders `••••`; operator-plane download without grant is refused. Sabotaging the plane check (leaking plaintext filename or serving bytes) FAILS.
- **RP-FI-5 (AC-G14-6) type/size fail-closed:** an over-size or non-allowlisted upload is refused before `Storage.put`; an empty content_type is refused. Widening the allowlist to `*` FAILS the deny-by-default test.
- **RP-FI-6 (AC-G14-7) fail-honest S3:** `S3.configured?/1` is false absent creds and `S3.put/3` returns `{:error, :not_configured}`; a stub returning `{:ok}` FAILS the fail-honest test (mirrors the delivery no-op probe).
