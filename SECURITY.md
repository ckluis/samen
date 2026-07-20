# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately through GitHub's
[private vulnerability reporting](https://github.com/ckluis/samen/security/advisories/new)
(the repository **Security** tab → *"Report a vulnerability"*). If that channel is
unavailable, email **ckluis@gmail.com** with the details and a way to reach you.

Expect a best-effort acknowledgement within a few days. Samen is a small, solo-maintained
foundry (see the authorship note in the [README](README.md)), so response times are
best-effort, not contractual.

## Supported versions

Samen is pre-1.0 and evolving. Only the latest tagged release and `main` receive security
fixes; there are no backports.

## Scope

Samen is a **foundry / substrate**, not a hosted service — this project operates no
production deployment. Reports about the framework's governance guarantees are especially
welcome, since those are the load-bearing claims:

- PII masking by default across both planes (tenant + operator);
- the vault, per-subject KMS keys, and crypto-shred / destruction oracle;
- two-plane isolation and masked impersonation;
- the hash-chained, append-only audit log.

Please note what is **by design, not a vulnerability**: several adapters ship as documented
**fail-honest stubs** (SMTP/ESP delivery, S3 storage, Stripe billing sync). An unconfigured
stub deliberately does no real work — it returns `{:error, :not_configured}` or a clearly
labeled no-op rather than a false success. Auth is likewise **host-owned** by design: Samen
governs the identity you bring; it does not ship a login/password/2FA system.
