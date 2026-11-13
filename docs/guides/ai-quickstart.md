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

### Adapter options (all optional, same config map)

    config :samen_core, Samen.AI,
      provider:
        {SamenAnthropic.Provider,
         %{
           api_key: System.get_env("ANTHROPIC_API_KEY"),
           model: "claude-opus-5-5",      # the default; an agent's `model:` or a call's `model:` wins
           max_tokens: 16_000,            # the default — thinking counts toward it
           effort: "medium",              # output_config.effort; unset = the model's default
           connect_timeout: 10_000,       # ms (default)
           receive_timeout: 300_000,      # ms, one attempt (default)
           call_budget_ms: 300_000,       # ms, the WHOLE call: attempts + retry waits (default:
                                          #   one receive timeout; an agent passes half its
                                          #   600 s watchdog, and a smaller value here wins)
           max_retries: 2                 # 429 / 529 / 5xx / failures to connect only
         }}

What the adapter does with a sealed payload (ADR-043 §5.1a, 2026-11-13): the payload's
`:system` instructions go in the `system` parameter (with a prompt-cache breakpoint), its
role-structured `:turns` become the `messages` — a tool call is a `tool_use` block, its result a
`tool_result` block with the same id, so tool output and tenant data reach the model as data,
never merged into the instructions — and the agent's tool definitions are sent natively with an
`input_schema`. A response cut off at `max_tokens` is `{:error, :truncated, usage}`, a refusal
`{:error, :refused, usage}`, an unknown stop reason `{:error, :unexpected_stop, usage}`; after the
bounded retries a 429 is `:rate_limited`, a 529 `:overloaded`, a timeout `:provider_timeout` (a
timeout is never retried: the work may have been done). The agent loop ends the turn as a failure
with that kind — never as an answer. Pick a model per agent with
`use Samen.AI.Agent, …, model: "claude-haiku-5-5"`, or per verb call with `model:`; the model that
actually answered is recorded on each agent turn row (`meta["model"]`).

## 4 · The live agent trajectory eval (opt-in, never in CI)

The keyless suites prove the request SHAPE (`samen_anthropic/test/request_shape_test.exs` asserts
the exact body for every agent-loop case). Whether a real model actually drives the loop is a
different question, answered only by a real call:

    cd samen_core
    SAMEN_AI_LIVE=1 ANTHROPIC_API_KEY=sk-ant-... \
      mix test test/ai_eval/agent_live_trajectory_test.exs --only ai_live

It runs two cases through the full governed loop against the real adapter: (1) one
`fetch_record` call, then a final answer that uses the result; (2) a requested owner assignment,
which must be PROPOSED and stop at the approval gate with nothing executed. Each case prints one
`[ai_live]` line (turns, tools called, answering model, tokens). It is excluded unless
`SAMEN_AI_LIVE=1`, skips without a key, and costs a few thousand tokens per case;
`SAMEN_AI_LIVE_MODEL=claude-haiku-5-5` runs it on a cheaper model. `samen_core` stays vendor-free
(INV-4): the test loads the adapter's source at run time and gives it an `:httpc` transport, so
the request it sends and the response it parses are the adapter's own.

## Honesty recap

| lane | provider | `simulated` | in CI? |
|---|---|---|---|
| keyless (default) | `Samen.AI.Provider.Fake` (`:test`) | `true` | yes (deterministic) |
| unwired, non-test | — | — (`{:error, :not_configured}`) | n/a |
| live (`SAMEN_AI_LIVE=1` + key) | e.g. `SamenAnthropic.Provider` | `false` | **never** |
| live agent eval (`SAMEN_AI_LIVE=1` + key, `--only ai_live`) | `SamenAnthropic.Provider` | `false` | **never** |
