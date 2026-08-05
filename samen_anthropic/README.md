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
- **No live calls in CI**: the test suite injects a fixture transport (the
  `samen_postmark` cassette precedent); the real Messages-API call
  (`SamenAnthropic.Transport`, via `req`) is exercised only behind the host opt-in
  `SAMEN_AI_LIVE=1` (ADR-043 §4).

## Host wiring

    config :samen_core, Samen.AI,
      provider: {SamenAnthropic.Provider, %{api_key: System.get_env("ANTHROPIC_API_KEY")}}

## Tests

    mix test
