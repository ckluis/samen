## Code Exploration — MANDATORY (codemunch)

**Agents: use `codemunch:search`/`codemunch:fetch` for exploration, not raw Read/Grep sweeps — this has been missed before (agents keep defaulting to plain Read/Grep); it is not optional. It stays mandatory.**

<CRITICAL>
You MUST use codemunch for ALL code exploration. This is NON-NEGOTIABLE. Do NOT ignore this rule.
Reading full files when a codemunch command exists for the task is a violation of your instructions.
</CRITICAL>

### WHEN this fires (the trigger — do NOT skip it because the task "looks small")

Your **FIRST** orientation action in any new task touching this codebase is codemunch, BEFORE any
Read/Grep/Glob. Concretely, if you are about to do ANY of the following, STOP and run codemunch first:

- read **more than one** source file to understand how something works → `codemunch:explore` / `codemunch:fetch`,
- **Grep/Glob a large tree** (`samen_core/`, `samen_web/`, `driftwood/`, `pawchart/`, `demo/`, or `docs/`)
  to find a function/type/symbol or its callers → `codemunch:search` / `codemunch:refs`,
- open a file just to see "what's in it" / where a symbol lives → `codemunch:search` then `codemunch:fetch`.

A single grep for one exact string in one known file is fine. A **sweep** (grep/read across a
directory to orient yourself) is exactly what codemunch replaces — route it through codemunch first.
"I'll just Read a few files to get my bearings" is the anti-pattern this rule exists to stop.

### Rules (enforced, no exceptions)

1. **NEVER read a full source file to understand what a function/class does.** Use `/codemunch:fetch <name>` instead. It reads ~35 tokens instead of ~8,000.
2. **NEVER use Grep or Glob to find functions, classes, or types.** Use `/codemunch:search <query>` instead. Supports filters: `kind:class`, `file:auth`, `in:ClassName`, `sig:ReturnType`.
3. **NEVER read multiple files to understand project structure.** Use `/codemunch:explore [path]` instead.
4. **NEVER use Grep to find symbol usages.** Use `/codemunch:refs <name>` instead.
5. **The ONLY exception**: Use Read when you need to Edit a file, since Edit requires file content in context.

### Decision tree

- Need to find a symbol? → `/codemunch:search`
- Need to read a symbol's code? → `/codemunch:fetch`
- Need to understand structure? → `/codemunch:explore`
- Need to find references? → `/codemunch:refs`
- Need to edit a file? → Read first, then Edit (this is the ONLY valid use of Read for source files)

The index auto-updates — no manual indexing needed.
