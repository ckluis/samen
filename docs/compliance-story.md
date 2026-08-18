# The GDPR / SOC 2 story — what Samen's substrate gives you, and what stays yours

**Read this first — the honesty boundary.** This is a **control-posture** document. It
describes how Samen's *architecture* supports the work a B2B buyer's security and
procurement team cares about under **GDPR** and **SOC 2**. It is **not** a certification, an
attestation, or a claim of legal compliance.

- Samen is **not SOC 2 certified** — there is no Type I or Type II report, no auditor, and no
  control period under observation.
- Samen has **not completed a GDPR audit, a DPIA, or a DPA process**, and ships no Data
  Processing Agreement.
- Samen **operates no production deployment**. It is a *foundry / substrate* on an open,
  **pre-merge branch** (`saas-readiness-phase-1`, PR #1), published so the architecture and
  its verification discipline are legible — not a hosted service and not a package on Hex.
- Nothing below asserts that *you*, the adopter, are compliant. Compliance is a property of a
  **deployed system, an organization, and its processes** — not of a substrate. What Samen
  gives you is a set of **GDPR-relevant capabilities** and controls that **support your SOC 2
  journey**, born into the object model instead of bolted on at the end.

Every control statement below names its **real mechanism** and cites its **proof** — a test,
a verifier, a game-day artifact, an ADR, or an independent verdict under
[`_orch/verify/`](../_orch/verify/). The load-bearing map is
[`docs/claim-evidence.md`](claim-evidence.md); section letters (§B, §C, §N …) refer to it.

---

## 1. What Samen is, and is not, for compliance

| Samen **is** | Samen **is not** |
|---|---|
| A substrate whose governance controls (masking, vault, erasure, audit) are enforced *by construction* and proven by a standing sabotage harness | A compliance certification, attestation, or legal opinion |
| A "born-compliant substrate" — the compliance-grade parts (PII vault, two-plane masking, crypto-shred, tamper-evident audit) are the storage format, not a later add-on | A guarantee that a system built on it is compliant — that depends on *your* deployment, DPO, policies, and processes |
| A set of GDPR-relevant *capabilities* and SOC 2-relevant *controls* you can point an auditor at | A signed SOC 2 report, a DPIA, or a DPA |
| Honest about its edges: what is proven locally vs. what is an operator TODO is labeled, never hidden | A hosted, production-operated service |

> The phrase **"born-compliant substrate"** appears in Samen's positioning. It always means
> *the controls are native to the object model* — it is used only adjacent to this honest
> split, never as a claim of certification.

---

## 2. Day one from Samen — controls the substrate provides

Each row is a mechanism that exists and is gated in the codebase today. "Proof" cites the
covering test/verifier/ADR/verdict.

| Capability (GDPR / SOC 2 relevance) | Mechanism in Samen | Proof |
|---|---|---|
| **PII minimized to ciphertext at rest** (GDPR Art. 5 data-minimisation / Art. 32 security) | Every `🔒` field writes a `vt_*` vault token through one chokepoint; plaintext is nowhere at rest. `no_pii_columns` refuses a `pii_*` column on a token-blind resource; `no_plaintext_pii` audits every tier. | claim-evidence §A R3, §C D2; `samen.verify.{no_plaintext_pii,no_pii_columns}` |
| **Masked by default on both planes** (access minimisation) | `%Masked{}` is the field's *normal* value. Tenant (or operator-with-grant) resolves clear; operator-without-grant renders `••••` across UI, JSON, CSV, and logs — by omission. `Samen.Api.PiiResolution` is the single per-plane resolver. | claim-evidence §B C2, §D E2/E3; `Samen.MaskingCase` three-proofs |
| **Right to erasure by crypto-shred** (GDPR Art. 17) | `Samen.Erasure.shred/2` destroys the subject's per-subject KMS key; their vaulted PII becomes undecryptable across live / replica / rollup / audit / PITR-history at once — key destruction, not row-chasing. | claim-evidence §C D3/D4; driftwood crypto-shred game-day (`reports/T5.4.md`) |
| **Erasure-completeness attested** (Art. 17 — "left every tier") | `mix samen.verify.erasure_completeness` discovers every out-of-DEK-envelope residue from the *live* schema (blind-index `_bidx` tombstones, `storage_key` blob-delete, custom-object bags, **agent transcripts**, `non_pii!` redaction) and fails closed if any lacks a registered erasure arm. | `samen.verify.erasure_completeness` (ADR-046 §6); claim-evidence §E H4 |
| **No PII egress to AI / tools** (Art. 5 purpose-limitation for AI processing) | INV-7: every AI egress is masked-by-default through one chokepoint; tool *definitions* and *results* are re-scrubbed hop-by-hop; a leaked `vt_` token refuses `{:error, :pii_egress_refused}`, fail-closed. | INV-7; claim-evidence §N; `ai_prompt_masking`, `adr047-a3-tools-eg2-verdict.json` |
| **Second-party, time-boxed reveal** (SOC 2 CC6 logical access; least privilege) | A reveal needs a *distinct* approver — enforced in policy **and** a DB `CHECK (granted_by <> requestor_id)`. Grants carry `expires_at`, cannot renew in place, and enqueue an Oban auto-revoke in the same transaction. | claim-evidence §B C3/C5; README hero; `reveal_grants_test` |
| **Propose-then-approve for AI writes** (SOC 2 CC change / least privilege) | An AI-proposed write executes *only* on a human approval, inside the decision transaction, as the **approver's** actor — never the agent's. Requester ≠ approver enforced by policy + DB `CHECK (apv_distinct_party)`. | ADR-047; `agent_write_test`; `adr047-a4-write-approval-verdict.json` |
| **Tamper-evident audit trail** (SOC 2 CC7 monitoring; GDPR Art. 30 records-of-processing substrate) | `aud_chain` is hash-chained and **append-only at the DB level** — a raw `UPDATE`/`DELETE` is refused by trigger; the chain detects any gap or payload forgery; it is tenant-readable and crypto-shreddable (token refs + key-destroyable ciphertext only). | claim-evidence §B C7; `audit_chain_test`; README hero |
| **RBAC + org-scoping** (SOC 2 CC6 access control) | Every action runs a policy check and emits `WHERE com_org_id = $1`; membership carries a role; cross-org reads structurally return zero rows. Cross-tenant views run on a separate **token-blind actor** over resources that have no `pii_*` columns at all. | claim-evidence §A R2, §B C4; `cross_org_test`, `samen.verify.no_pii_columns` |
| **Consent / suppression ledger** (GDPR Art. 6/7 lawful basis for marketing; ePrivacy) | Marketing send runs through a suppression chokepoint (`Samen.Marketing.Consent` / `Samen.Delivery`); a suppressed or unconsented address is refused at the single send seam — the kernel check is abbrev-derived, not a hardcoded table. | claim-evidence §L, §M; ADR-014; `sequence_send_test` |
| **Encryption & key handling** (SOC 2 CC6 / GDPR Art. 32) | Per-subject data-encryption keys in an external KMS *outside* the Postgres WAL/PITR surface; authenticated envelope crypto; a PITR restore brings back ciphertext, never the key. The reveal-request `reason` free-text runs a fail-closed PII-shape scan. | claim-evidence §C D4, §E H5; `Samen.Kms.*`; `Samen.PiiReasonScan` |
| **Backup verification** (SOC 2 A1 availability; recoverability) | `Samen.Backup.Verification` really `pg_restore`s a backup into a scratch DB and checksums / row-counts it; an unconfigured target returns `{:error, :not_configured}` (never a fake `:ok`); corrupt / missing / drifted restores fail loudly with token-blind telemetry. | `phase7-l4-l6-verdict.json` (L6, 13/13); sabotage 285 |
| **Multi-node availability** (SOC 2 A1 availability) | A real two-BEAM-node proof over one Postgres: exactly-once job fetch (SKIP LOCKED, no double-grab), insert-time dedup with a refutable control, and reveal auto-revoke **failover** (kill the enqueuing node; the survivor runs the scheduled revoke exactly once). | `phase7-l4-l6-verdict.json` (L4, 3/3) |
| **Change management, verified** (SOC 2 CC8) | Every guarantee ships a green proof, a red-path proof, and a committed **sabotage** that proves the test fails when the guarantee is broken (285 patches today, `ls scripts/sabotages/*.patch`). Migrations are expand/contract with a tested `down/0`, `lock_timeout`/`statement_timeout`, and a `contract_ready?` bake gate; `samen.verify.migrations` enforces it. | README verification story; `samen.verify.migrations`; claim-evidence §A R4/R5 |

---

## 3. Operator responsibility — what stays yours

Samen is a substrate. A running, compliant product needs work the substrate cannot do for
you. **No row here is a Samen deliverable** — each is your responsibility as the operator /
data controller.

| Area | Why it is yours |
|---|---|
| **Legal basis, DPO, and policies** | Lawful basis, retention schedules, a Data Protection Officer where required, privacy notices, and internal policies are organizational, not architectural. |
| **DPA / sub-processor agreements** | Samen ships no DPA. You contract with your KMS / hosting / email sub-processors and maintain your Art. 30 records-of-processing. |
| **The SOC 2 audit itself** | Samen provides controls an auditor can inspect; it does not provide an auditor, a control period, evidence collection cadence, or a report. Engaging a firm and running the observation window is yours. |
| **Production hosting & real infra wiring** | Real AWS KMS / DynamoDB / S3 Object-Lock, Neon PITR drills, a physical read replica, live ESP/Stripe keys, and Fly deploys are **operator TODOs** — locally simulated here (§6), not operated. |
| **Auth provider & identity** | Samen governs the identity you bring; it does not run a login/password/2FA *service*. You wire the OIDC / auth provider. |
| **Incident response & breach notification** | GDPR Art. 33/34 breach notification, monitoring alerting destinations, and IR runbooks are your operational processes. The substrate emits token-blind audit and failure telemetry; routing and responding to it is yours. |
| **Backup schedule & DR execution** | Samen ships a backup-*verification* job and a PITR game-day *harness*; scheduling real backups, running the real DR drill against your cloud, and owning the RTO/RPO numbers are yours. |
| **Data residency & tenant contracts** | Region choice, residency commitments, and per-tenant contractual terms are deployment/business decisions. |

---

## 4. GDPR — how the architecture supports each obligation (posture, not compliance)

| GDPR area | How Samen's architecture supports it | Honest limit |
|---|---|---|
| **Art. 17 — Right to erasure** | Crypto-shred makes a subject's PII undecryptable across every tier at once; `erasure_completeness` proves no residue escapes the erasure arms. | Proven against a local file-backed KMS + a `pg_dump` PITR sim; a real KMS/Neon erasure drill is an operator TODO. |
| **Art. 5 — Data minimisation** | PII exists only as a vault token or ciphertext downstream; token-blind analytics never carry `pii_*` columns. | You still decide *what* to collect; the substrate enforces *how* it is stored, not your collection policy. |
| **Art. 5(1)(b) — Purpose limitation** | The two-plane split and INV-7 AI chokepoint structurally prevent PII from flowing into operator analytics, logs, traces, or AI prompts by default. | Inference-blindness is bounded: k-anonymity/l-diversity floors are enforced; formal differential-privacy composition stays posture-under-construction (labeled honestly). |
| **Art. 30 — Records of processing** | The machine-readable catalog (`schema.dict.json`) plus the PII classification registry (`pii_classify`) form a live, enforced PII inventory — every PII column is declared and reviewed, or the build fails. | The catalog is an engineering inventory; mapping it into a formal Art. 30 register is your process. |
| **Art. 25 — Data protection by design & default** | Masking is the field's *default value*; the vault, org-scope, and audit are injected by the base macro. "By default" is literal here, not aspirational. | By-design ≠ certified; an auditor still evaluates your deployment. |
| **Art. 32 — Security of processing** | Envelope encryption with external per-subject keys, fail-closed reveal, tamper-evident audit, and a fail-closed verifier gate. | Real-cloud KMS/HSM posture and pen-testing are operator responsibilities. |
| **Art. 15/20 — Access & portability** | The versioned JSON:API over the same Ash resources gives a subject-scoped export path; tenant keys read their own org's PII in clear. | A packaged, subject-initiated DSAR export workflow is a product surface you assemble on the API, not a turnkey button. |

---

## 5. SOC 2 — Trust Services Criteria posture (supports your journey)

*Framing: these are controls that **support your SOC 2 journey**. Samen is not SOC 2
certified and this is not a gap analysis performed by an auditor.*

| TSC area | Supporting control in Samen | Proof |
|---|---|---|
| **CC6 — Logical & physical access** | Org-scoped RBAC; masked-by-default; second-party time-boxed reveal with a DB-enforced distinct-approver check; token-blind aggregate actor. | claim-evidence §B C2/C3/C4 |
| **CC7 — System monitoring** | Hash-chained, append-only, tenant-readable audit; token-blind failure telemetry on reveal, backup-verify, and delivery paths. | claim-evidence §B C7; L6 verdict |
| **CC8 — Change management** | Expand/contract migrations with tested `down/0` + bake gate; the 22-verifier fail-closed gate; the 285-patch sabotage harness proving every guarantee is refutable. | README verification story; `samen.verify.migrations` |
| **CC6.7 — Encryption / key management** | External per-subject KMS keys outside the WAL/PITR surface; authenticated envelope crypto; no PAN column can compile (billing is hosted-only). | claim-evidence §C D4, §K |
| **A1 — Availability** | Multi-node exactly-once + failover proof (L4); backup **verification** that really restores + checksums, fail-honest when unconfigured (L6). | `phase7-l4-l6-verdict.json` |
| **P / C — Privacy & confidentiality** | The whole two-plane masking + vault + crypto-shred thesis; INV-7 for AI processing. | claim-evidence §A–§E, §N |

---

## 6. What is simulated or an operator TODO (named, not hidden)

The same honest edges the [landing page](../index.html) and
[`claim-evidence.md`](claim-evidence.md) carry — repeated here so a procurement reader sees
them in one place:

- **The external KMS is real in mechanism, simulated in cloud.** The load-bearing exclusion
  (per-subject key outside the WAL/PITR surface) is proven identically by a `FileBacked` KMS
  and a `pg_dump` PITR drill (restore resurrects ciphertext; `reveal` returns
  `{:error, :unavailable}` against an empty key dir). Real AWS-KMS / Neon-PITR / S3
  Object-Lock wiring is an operator TODO.
- **Drilled RTO/RPO are local-sim floors.** The ≤30-min forward-fix / ≤2-h full-PITR numbers
  are targets pending the real cloud drill; `detection_ms` is a harness proxy.
- **Token-blind is not inference-blind.** k-anonymity + l-diversity floors are enforced,
  fail-closed; a per-cohort read budget guards differencing; formal ε-DP composition and
  t-closeness stay posture-under-construction. There is deliberately no flag claiming a
  guarantee the math does not have.
- **Adapters are fail-honest stubs by design.** Unconfigured SMTP/ESP, S3 storage, and Stripe
  billing return `{:error, :not_configured}` rather than a false success — surfaced, never
  faked.
- **Auth is host-owned by design.** Samen governs the identity you bring; it does not ship a
  login/password/2FA service.

---

*Maintained as part of the Samen foundry. For the full claim→proof map see
[`docs/claim-evidence.md`](claim-evidence.md); for the outward-claim audit see
[`docs/claim-sweep.md`](claim-sweep.md); for the security-reporting policy see
[`SECURITY.md`](../SECURITY.md).*
