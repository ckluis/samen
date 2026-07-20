# First Real Launch — the operator gate

**What this is.** Samen ships the close-the-first-contract 80% and a fail-honest boundary around
everything it does NOT own. The gap between "the dogfood boots on localhost" and "a paying tenant
logs in tomorrow" is a short, bounded list of **operator** tasks — the things that are honestly
labeled as YOUR job because a framework cannot safely own your identity provider, your payment
keys, your email reputation, or your KMS. This is that list. Walk it top-to-bottom to take a
vertical live. Nothing below is a code change to samen; each is a config/secret/provider you
bring, wired into a seam that already exists.

Legend: **[BLOCKER]** = a real tenant cannot safely use the product until this is done ·
**[HONESTY]** = the boundary is fail-honest today (it refuses rather than lies), so shipping
without it degrades gracefully but is not a breach · **[DRILL]** = a production-readiness rehearsal.

---

## 0 · Before you start

- [ ] Pick the vertical (`driftwood` is the worked reference for every item below).
- [ ] Read `docs/adr/031-byo-auth-launch-onramp.md` (auth), `docs/guides/byo-esp.md` (email),
      and `docs/adr/024-generated-deploy-fail-honest.md` + the generated `runbook.md` (deploy).
- [ ] Confirm the tree is green: `./ci.sh` ends `ROOT CI: ALL PASSED`.

## 1 · Auth — turn on the launch gate **[BLOCKER]**

The dev/dogfood path trusts a `?org=<uuid>` query param as identity. A real launch MUST derive
the tenant actor from an authenticated session. The seam is built (ADR-031); you arm it and bring
the credentials.

- [ ] **Arm the gate.** Set `config :driftwood, :auth_required?, true` in your prod config. This
      flips `Samen.Web.CurrentOrg`'s actor derivation to fail-closed: no authenticated principal →
      no actor; an org outside the user's authorized set → never resolved.
- [ ] **Bring an identity provider.** Either:
  - run **`mix phx.gen.auth`** in the host and have its `log_in_user` call
    `Samen.Web.Auth.put_current_user(conn, user_id)` on success; or
  - wire an **external IdP** (OIDC/SAML) callback that does the same; or
  - for a bounded internal launch, provision **`config :driftwood, :auth_credentials`** records
    (the reference PBKDF2 verifier — see ADR-031 §4). NEVER commit a credential to the repo.
- [ ] **Point the membership seam at real rows.** For production, change the router's
      `:authorized_orgs` label from `{Driftwood.Auth, :authorized_org_ids, []}` to a function over
      `Identity.Membership` (the authorization source of truth), so a user's org set is their real
      memberships, not the credential store.
- [ ] **Verify.** An unauthenticated request to a tenant route redirects to `/login`; a logged-in
      user only ever reaches their own orgs; `?org=<someone-else>` lands them on their own org.
- [ ] *(carry)* Operator-plane (SaaS-staff) auth: the `/operator/*` surfaces still assume a
      trusted seat. Gate them with the same principal seam before exposing them off-localhost.

## 2 · Email delivery — bring an ESP **[HONESTY]**

Outbound email today routes through the fail-honest delivery boundary (`Samen.Delivery.Adapter`):
`LocalSink` captures in dev; the `Smtp`/`Api` skeletons return `{:error, :not_configured}` rather
than faking a send. A marketing "send" will not actually deliver until you wire a provider.

- [ ] **Follow `docs/guides/byo-esp.md`** — implement the `Samen.Delivery.Adapter` behaviour in
      your HOST (gen_smtp, or an HTTP ESP: SendGrid/Postmark/SES), supply creds via config, and
      confirm `configured?/1` returns `true` only when creds are present.
- [ ] **Verify** a real send reaches `:delivered` only via a configured adapter returning
      `{:ok, receipt}` (Invariant D1) — an unconfigured adapter blocks, never lies.

## 3 · Billing — bring live Stripe keys **[HONESTY]**

The Stripe mirror schema is real; `SyncAdapter.Stub` returns `{:ok, %{stub: true}}` (labeled).

- [ ] Implement the `SyncAdapter` behaviour against the live Stripe API; supply live keys via
      secrets (never committed). Until then, billing is a governed mirror with a stubbed sync —
      honest, but not moving real money.

## 4 · Secrets & KMS — real key material **[BLOCKER]**

- [ ] **KMS.** Dev uses a file-backed keystore (`priv/dev_keystore/`, gitignored). Production
      MUST inject AWS KMS (+ DynamoDB wrapped-DEK store + S3 Object-Lock) via the deploy runtime.
      The generated `config/runtime.exs` RAISES on missing `SAMEN_KMS_*` (ADR-024) — it will not
      boot half-configured.
- [ ] **`SECRET_KEY_BASE` / `DATABASE_URL` / `PHX_HOST`.** Injected from the environment by the
      deploy runtime (it raises naming any missing secret). Never commit them.
- [ ] Confirm `/readyz` returns 200 only when Postgres + the KMS wrapped-DEK store + Oban all
      answer (it is the deploy traffic gate; `/healthz` stays a static liveness 200).

## 5 · Deploy **[BLOCKER]**

- [ ] Generate/adopt the deploy artifacts (`mix samen.gen.app --deploy` or the committed
      `fly.toml`/`runtime.exs` pattern); front the endpoint with TLS; point `DATABASE_URL` at a
      managed Postgres (Neon) branch. See `docs/adr/024-*` and the generated `runbook.md`.

## 6 · Production drills **[DRILL]**

- [ ] **Neon PITR** restore drill (the crypto-shred game-day rehearses the erasure math locally).
- [ ] **KMS key rotation / destruction** rehearsal against the real store.
- [ ] **ClickHouse ClickPipes** activation if you use the CDC analytics tier.

---

## The honest boundary, restated

Every item above is a place where samen **refuses rather than pretends**: an unconfigured ESP
blocks the send, a stubbed Stripe sync is labeled, a missing KMS secret raises at boot, and — as
of F2 — an unauthenticated prod request gets no actor. The launch gate is walking this list until
each fail-honest boundary is backed by the real provider you bring.
