# S0.7 — pii_reads AST feasibility — resolved versions

Permanent record of the toolchain that compiled and ran this spike.

| Component | Version |
|---|---|
| Elixir | 1.20.2 (compiled with Erlang/OTP 29) |
| Erlang/OTP | 29 [erts-17.0.3] |
| Hex deps | **none** (see below) |

## Why zero dependencies

S0.7 is a pure AST-analysis feasibility spike. The walker uses only the
Elixir standard library:

- `Code.string_to_quoted/2` — parse source to quoted AST
- `Macro.prewalk/3` — walk argument sub-expressions

No Ash / AshPostgres / Spark / Oban / Postgres is required for this spike —
the PII-declaration registry is stubbed (`PiiReads.PiiRegistry`), which is
exactly what the plan (S0.7 row) asks for. Keeping deps at zero makes the
feasibility signal about the AST approach itself, not a framework.

There is therefore no `mix.lock` (nothing to lock).

In the real `samen_core`, the stubbed registry is replaced by
`Ash.Resource.Info` introspection over each resource's `pii do` block
(plan D2 / C3), and the walker scans `lib/**/*.ex` project sources.
