# AI plane quickstart — keyless fake → one real result

The `Samen.AI` plane (ADR-043) is **keyless by default and fail-honest always**: it builds,
tests, and red-teams with zero API keys. This guide takes a builder from the keyless
deterministic lane to one real model result in two steps.

## 0 · What "keyless" gets you (and its one honest limit)

With NO provider wired:

- In `:test`, an unwired `Samen.AI.complete/4` resolves to the deterministic
  `Samen.AI.Provider.Fake` — a stable, recorded double whose `%Samen.AI.Completion{}` is
  clearly labeled **`simulated: true`** (and whose `:text` carries the legacy
  `"fake-completion:<16hex>"` prefix). It proves the masking chokepoint + assembly path
  provider-independently; it is NOT model cognition.
- In any other env, an unwired call is fail-honest: `{:error, :not_configured}` — never a
  fabricated `{:ok, _}`. `Samen.AI.configuration_hint/0` prints exactly how to fix it.
- Keyless **semantic search ranks by HASH distance, not meaning**
  (`Samen.AI.Embedder.Deterministic` is a bag-of-tokens hash projection): a self-query lands
  at distance 0 and shared tokens rank nearer, but synonyms/paraphrase do NOT. Meaningful
  semantic ranking needs a **live embedder** — this is the inherent keyless limitation, not a
  bug to fix in the hash embedder.

## 1 · The keyless smoke (no key, deterministic, clearly labeled)

    mix samen.ai.smoke

Runs one completion through the plane. With no key it dispatches to the deterministic Fake and
prints a result banner marked **SIMULATED** — so you can see the plane end-to-end without a
key, and never mistake a fake for a real answer.

## 2 · Wire a real provider (one config line)

Add to your host config (e.g. `config/runtime.exs`):

    config :samen_core, Samen.AI,
      provider: {SamenAnthropic.Provider, %{api_key: System.get_env("ANTHROPIC_API_KEY")}}

That is the ONLY authored line — the capability lives in `samen_core`; any scope then calls
`Samen.AI.complete/4` (framework-first, ≈0-LOC vertical adoption). See
`samen_anthropic/README.md`.

## 3 · One real result (guarded by `SAMEN_AI_LIVE=1`, never in CI)

    export ANTHROPIC_API_KEY=sk-ant-...
    SAMEN_AI_LIVE=1 mix samen.ai.smoke --prompt "Say hello in one short sentence."

With a key AND `SAMEN_AI_LIVE=1`, the smoke transmits a real request through the provider and
prints a result banner marked **LIVE** (`simulated: false`). The live lane is the sole path
that makes an external, billable call — it is **never** exercised by `./ci.sh` (the keyless
deterministic lane is what CI runs). Without `SAMEN_AI_LIVE=1`, the task stays keyless even if
a key is present, so you cannot accidentally spend money from CI.

## Honesty recap

| lane | provider | `simulated` | in CI? |
|---|---|---|---|
| keyless (default) | `Samen.AI.Provider.Fake` (`:test`) | `true` | yes (deterministic) |
| unwired, non-test | — | — (`{:error, :not_configured}`) | n/a |
| live (`SAMEN_AI_LIVE=1` + key) | e.g. `SamenAnthropic.Provider` | `false` | **never** |
