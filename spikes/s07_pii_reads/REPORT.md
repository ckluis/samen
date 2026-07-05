# S0.7 — `pii_reads` AST feasibility spike — REPORT

**Status:** green (GO at Gate 0, caveat named). This report was reconstructed by the orchestrator from the S0.9 spike record and the independent audit, because the original agent was blocked from writing report files; full findings live in `docs/gate-0-report.md` § S0.7.

## Result

A syntactic AST match (`Code.string_to_quoted` + `Macro.prewalk`, stdlib only, zero deps) over Ash sources is feasible and cheap:

- **9/9 seeded direct leaks caught (100%)** — Logger calls, span attributes, interpolation into IO.puts.
- **0 false positives** on declaration/reveal sites (target was < ~1/50).
- **3 laundered leaks documented as expected misses** — a pure AST match sees an opaque local after a helper hop; laundering is the J2 sink-schema allow-list's job (per the plan's layered design), out of scope here.
- 13/13 tests green. Fail-closed at both ExUnit and shell level: `mix pii_reads.verify corpus/leaks` → exit 1; parse errors also fail closed (never silently skipped).
- Red paths independently re-verified as non-vacuous: three sabotage mutations (disable reveal suppression, disable field-read taint, force exit 0) each flipped the RED PATH tests to FAIL.

## Caveats carried into C3 productionization (T1.8b)

1. **Reveal-scope suppression is a lexical name-prefix heuristic** — any function whose name starts with `reveal` suppresses ALL sinks in its body (`def reveal_report(c), do: Logger.info("ssn=#{c.pii_ssn}")` yields zero findings). Production C3 must key on real Ash `action :reveal` introspection, not the name prefix.
2. The PII registry is stubbed; the real implementation introspects `Ash.Resource.Info` over `pii do` blocks (walker contract unchanged).
3. Aliased sink modules (`alias Logger, as: L`) evade the spike; resolve from module context or rely on J2.
4. The J2 sink-schema allow-list is the named laundering backstop and is NOT implemented here (plan T2.7).
