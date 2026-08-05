defmodule Samen.AI.Provider do
  @moduledoc """
  The core-defined AI-provider contract (ADR-043 §5.1; D1, T64) — hand-built, NOT
  `ash_ai` (ADR-037 §5.6 REJECT: its dependency shape puts `req_llm` vendor clients into
  core against INV-4, it has no chokepoint concept, and `load:` reaches private
  attributes). `samen_core` defines this behaviour, the `Samen.AI.MaskedPayload` /
  `Samen.AI.Completion` structs, and the honest `Samen.AI.Provider.Fake` test double; it
  references NO vendor module and pulls NO HTTP client. Every vendor SDK/HTTP dependency
  lives in a separate first-party-but-separate adapter package (the reference adapter, on the
  first-party-but-separate delivery/billing adapter layout precedent, §8.1), per INV-4.

  ## Two callbacks, both accepting ONLY the sealed payload (the INV-7 seam)

  Both callbacks take a `Samen.AI.MaskedPayload.t()` as their first argument. This is the
  load-bearing by-construction gate (ADR-043 §3.2): an adapter implementation
  pattern-matches `%Samen.AI.MaskedPayload{} = payload` in its function head, so a raw
  string/map cannot reach it — it refuses by `FunctionClauseError` (the runtime
  clause-refusal posture `Samen.Type.VaultField.dump_to_native/2` ships). `Samen.AI.Chokepoint`
  is the sanctioned mint site; an out-of-chokepoint `MaskedPayload` construction — static
  literal OR dynamic (`struct/2`, `struct!/2`, `Kernel.struct/2`, `apply(Kernel, :struct, ...)`,
  `%{__struct__: ...}`) — is DETECTED by the `Samen.AI.ChokepointAntiBypassProbeTest` AST scan
  (§3.2 single-mint). Elixir does not statically type behaviour-callback arguments, so this is
  a **runtime** clause guarantee plus a **CI-enforced detection** guarantee — not a
  type-impossibility (the honest residual: runtime-computed metaprogramming is beyond static
  AST detection).

  ## The fail-honest contract (ADR-014/024/026 shape, binding — ADR-043 §4)

  An unconfigured adapter (no API key wired) NEVER returns `{:ok, _}` for work it did not
  do — it returns `{:error, :not_configured}`. A capability the adapter genuinely lacks
  (e.g. a provider with no embeddings endpoint) returns `{:error, :not_implemented}`. A
  canned `{:ok, _}` from a keyless adapter is the exact lie the sabotage harness exists to
  catch (CLAUDE.md fail-honest contract; `Samen.Delivery.Smtp` / `Samen.Files.Storage.S3`
  precedents).

  ## Provider resolution (host config — the `Samen.Delivery.Chokepoint.decide/3` mirror)

      config :samen_core, Samen.AI, provider: {MyProvider, %{api_key: "..."}}

  Unwired in `:test` resolves to `Samen.AI.Provider.Fake` (the keyless CI lane, §4);
  unwired in any other env returns `{:error, :not_configured}` (blocked, never faked) —
  see `Samen.AI.provider_for/2`.
  """

  @doc """
  Generate a completion for a sealed payload. Returns `{:ok, %Samen.AI.Completion{}}`
  ONLY when a configured provider genuinely produced output; `{:error, :not_configured}`
  when unconfigured (fail-honest); `{:error, term()}` on a provider-side failure. MUST
  accept ONLY `%Samen.AI.MaskedPayload{}` (§3.2 — refuse anything else by function clause).
  """
  @callback complete(Samen.AI.MaskedPayload.t(), config :: map()) ::
              {:ok, Samen.AI.Completion.t()} | {:error, :not_configured | term()}

  @doc """
  Embed a sealed payload's input, returning one vector per input segment. Same
  MaskedPayload-only + fail-honest contract as `complete/2`. (The embeddings plane — the
  deterministic CI embedder, pgvector, the embeddable-field allowlist — is T67; a provider
  with no embeddings endpoint returns `{:error, :not_implemented}` honestly.)
  """
  @callback embed(Samen.AI.MaskedPayload.t(), config :: map()) ::
              {:ok, [[float()]]} | {:error, :not_configured | term()}
end
