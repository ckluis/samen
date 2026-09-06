---
project: Listudy
url: https://github.com/ArneVogel/listudy
category: Education
relevance: low
verdict: Elixir/Phoenix chess-training app on a dated stack (Phoenix ~1.5, LiveView ~0.15, Pow auth) with no multi-tenancy or PII concerns — same language family as samen but nothing architecturally load-bearing to lift beyond a passing gettext reference.
---

# Listudy — evaluation vs samen

## What the project is

Listudy (listudy.org, AGPL-3.0, ~390 stars/61 forks, 579 commits, actively developed) is a single-tenant, consumer-facing chess training platform: opening repertoire study, tactics drills, and spaced-repetition review scheduling, plus a Python/python-chess side-process for generating opening-position SVG images. It is built on Elixir + Phoenix (~1.5.1) + Phoenix LiveView (~0.15) + Ecto/Postgrex against PostgreSQL, with Pow for authentication, Arc/Arc Ecto for file uploads, HTTPoison for outbound HTTP, and Gettext for translated PO-file i18n. Standard `mix phx.server` deployment, no containerization or IaC visible in the README, no mention of billing, multi-tenancy, admin/operator plane, or any data-governance concerns — it is a straightforward hobby-to-mid-size Phoenix CRUD app serving one user population with one set of permissions.

The domain (chess pedagogy) and the product shape (single-org, single-plane, no tenant/account boundary at all) have essentially nothing in common with samen's reason for existing — samen's whole moat is multi-tenant PII vaulting, two-plane masking, and verification discipline around a SaaS holding-company substrate. Listudy has no tenants, no PII vault, no reveal/audit story, no billing, and no operator cockpit to compare against samen's equivalents. Its Phoenix/LiveView versions are also several major versions behind samen's pinned stack (Phoenix 1.8.9 / LiveView 1.2.9 vs Phoenix 1.5 / LiveView 0.15 here), so even framework-idiom comparisons (e.g., LiveView upload patterns, function-component kits) would be comparing against an outdated baseline rather than current best practice.

## What samen could adopt

1. **Gettext-based PO-file i18n as a reference implementation** — What: Listudy ships working `priv/gettext/*/LC_MESSAGES/*.po` translations wired through the standard Phoenix Gettext backend, with contributor guidance on preserving `%{name}` interpolation placeholders. Why it fits samen: samen's own gap register explicitly flags G24 (i18n/timezone/currency: USD+UTC hardcoded, no gettext) as an open item — Listudy is a working, if minimal, example of the exact library samen would adopt to close that gap, showing the PO workflow and translator-facing conventions. Effort: S (reference only; samen's actual implementation is a will-need-its-own-design task given multi-tenant/masked-string interaction — a `%Masked{}` value must never leak into an interpolated, translator-editable string).
2. **Spaced-repetition scheduling as a pattern, if a samen-built vertical ever needs it** — What: Listudy's tactics/opening review queues imply an SM-2-style or similar interval scheduler tied to per-user attempt history. Why it fits samen: not a foundry-level need (no current samen vertical does spaced repetition), but if a future vertical (e.g., a training/LMS-style product) is built on samen, this is a small, well-trodden algorithm worth a five-minute glance rather than a discovery task. Effort: S, and speculative — do not pull this forward without a concrete vertical requiring it.

## What to ignore and why

- **Pow for authentication** — samen already has a considerably deeper, generator-emitted identity spine (ADR-035: atomic org/user/membership registration, OIDC via assent, TOTP via nimble_totp, vaulted recovery codes, deterministic session eviction) that Pow does not match; no reason to look at Pow's design.
- **Arc/Arc Ecto file uploads** — both are effectively unmaintained relative to samen's own LiveView upload chokepoint (`Samen.Files.ChokepointGuard`, quarantine-by-default); samen's version already encodes a security posture (chokepoint-everything) that a generic upload library does not.
- **HTTPoison as HTTP client** — samen's adapter packages standardized on `req` (ADR posture); no reason to introduce a second HTTP client.
- **Overall product/UI patterns** — single-tenant, single-plane, no masking/PII/audit concerns; nothing here models the two-plane, vault-chokepoint, or aggregate-token-blind architecture that is samen's actual hard problem. This is a domain-mismatch case (education/chess vs B2B multi-tenant SaaS substrate), not a hidden-gem case.
