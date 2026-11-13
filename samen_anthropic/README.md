# samen_anthropic

The first-party-but-separate **Anthropic** AI-provider adapter package (ADR-043 §5.1;
T64/D1). Implements `Samen.AI.Provider` for Anthropic's Messages API.

- **Path-deps on `samen_core` ONLY** (never `samen_web`), the `samen_stripe`/
  `samen_postmark` §8.1 layout precedent. Every vendor/HTTP dependency (`req`) lives
  here, never in `samen_core` (INV-4).
- **Keyless / fail-honest** (ADR-043 §4; ADR-014/024/026): with no `api_key`,
  `complete/2` returns `{:error, :not_configured}` — never a fake `{:ok, _}`. Anthropic
  has no embeddings endpoint, so `embed/2` honestly returns `{:error, :not_implemented}`.
- **By-construction raw-refusal** (the INV-7 seam): both callbacks accept ONLY a
  chokepoint-minted `%Samen.AI.MaskedPayload{}` — a raw string/map refuses by
  `FunctionClauseError`, so unmasked input cannot reach Anthropic.
- **Context overflow → `:context_overflow`** (ADR-048 §6 Level 2; issue #11): a 400
  "prompt is too long" is `{:error, :context_overflow}` (nothing was spent), and a 200 with
  `stop_reason: "model_context_window_exceeded"` is `{:error, :context_overflow, usage}` —
  truncated, so never handed back as a completion, and billed as a failed attempt. Usage
  keeps cached input in its own bucket: `input_tokens` = `input_tokens +
  cache_creation_input_tokens` (fresh), `cached_input_tokens` = `cache_read_input_tokens`.
- **Instructions apart from data** (ADR-043 §5.1a, 2026-11-13): the sealed payload's `:system`
  goes in the `system` parameter (cache breakpoint), its role-structured `:turns` become the
  `messages` (`tool_call` → `tool_use`, `tool_result` → `tool_result` with the same id and
  `is_error`), the agent's tools are sent natively with an `input_schema`
  (`native_tools?/0` is `true`). A payload with no turns is sent as before: one user message.
- **Stop reasons are honest**: only `end_turn` / `stop_sequence` / `tool_use` are completions;
  `max_tokens` is `{:error, :truncated, usage}`, `refusal` `{:error, :refused, usage}`, anything
  else `{:error, :unexpected_stop, usage}`. Default model `claude-opus-5-5` (a payload's
  `meta.model` wins), default `max_tokens` 16 000.
- **Transport**: explicit `connect_timeout` (10 s) / `receive_timeout` (300 s); bounded retry
  (`SamenAnthropic.Retry`) on 429, 529, 5xx and connection failures, honouring `retry-after`;
  never on another 4xx or a timeout. Then: `:rate_limited`, `:overloaded`, `:provider_timeout`.
- **No live calls in CI**: the test suite injects a fixture transport (the
  `samen_postmark` cassette precedent); the real Messages-API call
  (`SamenAnthropic.Transport`, via `req`) is exercised only behind the host opt-in
  `SAMEN_AI_LIVE=1` (ADR-043 §4).

## Host wiring

    config :samen_core, Samen.AI,
      provider: {SamenAnthropic.Provider, %{api_key: System.get_env("ANTHROPIC_API_KEY")}}

That one line is the whole opt-in. `Samen.AI.configuration_hint/0` prints it at runtime when a
call returns `{:error, :not_configured}`.

## Quickstart (keyless fake → one real result)

See `docs/guides/ai-quickstart.md`. TL;DR:

    mix samen.ai.smoke                       # keyless: deterministic fake, labeled SIMULATED
    SAMEN_AI_LIVE=1 mix samen.ai.smoke ...   # with a key: one REAL completion (never in CI)

## Tests

    mix test
