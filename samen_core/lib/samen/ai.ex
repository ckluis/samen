defmodule Samen.AI do
  @moduledoc """
  The `Samen.AI` kernel — the public API surface for AI calls (ADR-043 §5; D1, T64).
  Hand-built on the shipped masking substrate (NOT `ash_ai` — ADR-037 §5.6 REJECT).

  ## Routed through the chokepoint by construction

  `complete/4` and `embed/3` are THIN: their bodies route through `Samen.AI.Chokepoint`,
  which is the only module that mints a `%Samen.AI.MaskedPayload{}` and the only module
  that invokes a `Samen.AI.Provider` callback. There is **no kernel function that reaches a
  provider without minting a sealed payload first** — it is structurally impossible for the
  kernel to hand a provider anything but a chokepoint-minted `%MaskedPayload{}` (§5.3), and
  `Samen.AI.ChokepointAntiBypassProbeTest` proves no one else constructs one either
  (RP-AI-1). The verbs (T68), the support operator (T70), MCP (T69), and the CRM/analytics
  surfaces (T71) all call THIS kernel, never a provider.

  ## Provider resolution (fail-honest, keyless-by-default — §5.2, the Delivery mirror)

      config :samen_core, Samen.AI, provider: {MyProvider, %{api_key: "..."}}

  `provider_for/2` (the `Samen.Delivery.Chokepoint.decide/3` analog) resolves the
  host-wired `{module, config}`. UNWIRED in `:test` ⇒ `Samen.AI.Provider.Fake` (the keyless
  CI lane); UNWIRED in any other env ⇒ `{:error, :not_configured}` (blocked, never a fake
  `{:ok, _}` — ADR-014/024/026). A wired-but-unconfigured adapter (the reference provider
  package with no key) returns its OWN `{:error, :not_configured}` from `complete/2`. A per-org
  provider override is out of scope for this run (§5.2).

  ## ≈0-LOC vertical adoption (§5.3, INV-5)

  A vertical adopts AI the way it adopts everything else: the capability lives in
  `samen_core`, and the host's ONLY authored line is the provider config above — then any
  scope calls `Samen.AI.complete/4`. No per-vertical wiring, no re-implementation (the
  leverage guard). See `test/ai/adoption_smoke_test.exs`.

  ## T64 scope

  T64 ships the kernel + the `Samen.AI.Provider` behaviour + the `%MaskedPayload{}` type +
  the chokepoint SEAM + `Provider.Fake` + the reference adapter package. The full masking pipeline
  behind `Samen.AI.Chokepoint.seal/3` (resolve bindings via `PiiResolution` egress mode,
  assemble from the versioned Prompt resource + catalog grounding, the sound scrub scanner)
  is **T65**; the six intelligence verbs are **T68**. This kernel's `complete/4` assembles
  its payload from the given `prompt_ref` + `bindings` minimally until T65 formalizes it.
  """

  alias Samen.AI.Chokepoint

  @configuration_hint """
  No AI provider is wired, so Samen.AI is fail-honest ({:error, :not_configured}). To wire a \
  real provider, add to your host config (e.g. config/runtime.exs):

      config :samen_core, Samen.AI,
        provider: {MyProvider, %{api_key: System.get_env("MY_PROVIDER_API_KEY")}}

  (MyProvider is your host's Samen.AI.Provider adapter package — the reference adapter and \
  its concrete config one-liner are documented in docs/guides/ai-quickstart.md.) Keyless (no \
  config) resolves to the deterministic Samen.AI.Provider.Fake in :test only (CI lane); any \
  other env stays {:error, :not_configured}. Try `mix samen.ai.smoke`.\
  """

  @doc """
  A human-facing pointer to the provider-config one-liner (T152 DX). The machine-readable
  fail-honest return of `complete/4`/`embed/3`/`search/3` is UNCHANGED — still the bare
  `{:error, :not_configured}` atom the contract (ADR-014/024/026, T141) and the sabotage
  harness depend on. This hint is a SEPARATE, additive guidance path: it never appears in
  the error term, it only tells a builder WHERE the fix lives (the reference-adapter config
  documented in `docs/guides/ai-quickstart.md`) so `:not_configured` stops being a dead end.
  Kept vendor-free (INV-4) — it names no adapter package, only the generic config shape.
  """
  @spec configuration_hint() :: String.t()
  def configuration_hint, do: @configuration_hint

  # Governs the unwired-provider fallback: only `:test` degrades to the Fake — everything
  # else (including a bare release runtime) is fail-honest `{:error, :not_configured}`.
  #
  # T66 FIX (found while wiring the D9 catalog into demo — a REAL host, not samen_core's own
  # test fixtures): a COMPILE-TIME `@compiled_env Mix.env()` (the
  # `Samen.Notifications.EmailDispatchWorker` / `Samen.Delivery.Lifecycle.EmailWorker`
  # precedent this kernel originally copied) is release-safe but WRONG for a path
  # dependency — Mix compiles dependencies (samen_core, from ANY host's perspective) under
  # `:prod` regardless of the host's real `MIX_ENV`, so `demo`/`driftwood`/`pawchart`
  # running their OWN `mix test` baked `:prod` into this attribute, making the ADR-043 §5.2 /
  # M9 "unwired in `:test` ⇒ the keyless Fake" promise silently false for every vertical
  # except samen_core's own suite (verified live: `Samen.AI.complete/4` returned
  # `{:error, :not_configured}` inside `demo`'s test env before this fix). `resolved_env/0`
  # checks for Mix AT RUNTIME instead — `Code.ensure_loaded?/1` is `false` in a compiled
  # release (Mix is genuinely absent there, so the release-safety concern is preserved: the
  # `Mix.env()` branch is never reached outside a `mix` invocation) and `true` during any
  # `mix test`/`mix run`, where `Mix.env()` is a single env-wide value set once by the CLI —
  # correct regardless of which app's dependency graph compiled the calling code.
  #
  # T66-F2 fix-round (delta-verifier finding — regression): `Code.ensure_loaded?(Mix)` is
  # `true` whenever the `:mix` BEAM files are simply on the code path, EVEN IF the `:mix`
  # OTP application was never started (or was stopped) — `Mix.env/0` then raises
  # `ArgumentError` (its backing ETS table does not exist), live-reproduced as
  # `Samen.AI.complete/4` raising instead of returning `{:error, :not_configured}`. That is
  # fail-SAFE (a crash), not fail-HONEST (a clean error term) — the exact regression this
  # whole rewrite exists to avoid. `env_reader.()` is wrapped in the `rescue` below so ANY
  # failure reading the env (missing ETS table, a stopped `:mix` app, a future Mix internals
  # change) degrades to `:prod` — never a raise out of `complete/4`/`embed/3`. `env_reader` is
  # an injectable seam (default `&Mix.env/0`) so a test can model "Mix.env/0 raises" without
  # touching the real `:mix` application's live state (which would risk destabilizing the
  # whole shared test run).
  @doc false
  @spec resolved_env((-> atom())) :: atom()
  def resolved_env(env_reader \\ &Mix.env/0) do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      env_reader.()
    else
      :prod
    end
  rescue
    _ -> :prod
  end

  # The `:env_reader` opt seam (test-only, T66-F2) — defaults to the real `&Mix.env/0`.
  defp env_reader(opts), do: Keyword.get(opts, :env_reader, &Mix.env/0)

  @doc """
  Generate a completion in the calling actor's `scope` (ADR-043 §5.3). Routes through
  `Samen.AI.Chokepoint`: assemble → seal → dispatch to the resolved provider. Returns
  `{:ok, %Samen.AI.Completion{}}`, or `{:error, :not_configured}` when no provider is wired
  (fail-honest), or `{:error, :pii_egress_refused}` when the payload fails the scrub, or
  `{:error, term()}` (normalized, EG6) on a provider failure.

  `prompt_ref` is the prompt text / segment(s) and `bindings` the record/value bindings.
  (T65 formalizes `prompt_ref` as the versioned Prompt resource ref and resolves `bindings`
  through `Samen.Api.PiiResolution` in egress mode; T64 assembles them minimally.)

  ## Options

    * `:provider` — `{module, config}` override (else host config, else the env fallback)
    * `:grounding` / `:meta` — passed through to the sealed payload. `:grounding` defaults to
      the D9 runtime catalog (`Samen.AI.Catalog.grounding/2`, ADR-043 §8, T66) when omitted —
      "the kernel consumes it for grounding" so prompt context is catalog-DERIVED, never a
      hand-written string. Pass `:domains` / `:resources` to steer which resources the
      auto-grounding introspects (else the host's registered `:ash_domains`); pass an explicit
      `:grounding` to opt out entirely.
    * `:env_reader` — test-only seam (`Samen.AI.resolved_env/1`, T66-F2): overrides how the
      unwired-provider env fallback is read. Never set this outside a test.
  """
  @spec complete(term(), term(), map() | keyword(), keyword()) ::
          {:ok, Samen.AI.Completion.t()} | {:error, term()}
  def complete(scope, prompt_ref, bindings \\ %{}, opts \\ []) do
    case provider_for(opts, resolved_env(env_reader(opts))) do
      {:error, :not_configured} = err ->
        err

      {provider, config} ->
        segments = assemble(scope, prompt_ref, bindings)
        opts = ensure_grounding(scope, opts)
        Chokepoint.complete(provider, config, :complete, segments, opts)
    end
  end

  @doc """
  Embed `source` in the calling actor's `scope`. Routes through `Samen.AI.Chokepoint`'s
  `:embed` seam (the embeddings plane proper — pgvector, the deterministic embedder, the
  embeddable-field allowlist — is T67). Same resolution + fail-honest contract as
  `complete/4`.
  """
  @spec embed(term(), term(), keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed(_scope, source, opts \\ []) do
    case provider_for(opts, resolved_env(env_reader(opts))) do
      {:error, :not_configured} = err ->
        err

      {provider, config} ->
        Chokepoint.embed(provider, config, List.wrap(source), opts)
    end
  end

  @doc """
  Resolve the `{module, config}` provider pair (the `Samen.Delivery.Chokepoint.decide/3`
  analog, pure + directly testable). `opts[:provider]` first, then host config
  (`config :samen_core, Samen.AI, provider: ...`), then the env fallback: `:test` ⇒
  `{Samen.AI.Provider.Fake, %{}}`; any other env ⇒ `{:error, :not_configured}`.
  """
  @spec provider_for(keyword(), atom()) :: {module(), map()} | {:error, :not_configured}
  def provider_for(opts, env) do
    case Keyword.get(opts, :provider) || configured_provider() do
      {module, config} when is_atom(module) and is_map(config) -> {module, config}
      _ -> unwired(env)
    end
  end

  defp unwired(:test), do: {Samen.AI.Provider.Fake, %{}}
  defp unwired(_env), do: {:error, :not_configured}

  defp configured_provider do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(:provider)
  end

  # Skeleton assembly (T65 owns the sound resolve→assemble pipeline). Flatten the prompt
  # ref + bindings into an ordered segment list the chokepoint seals; the scrub still runs.
  defp assemble(_scope, prompt_ref, bindings) do
    List.wrap(prompt_ref) ++ binding_segments(bindings)
  end

  defp binding_segments(bindings) when is_map(bindings), do: Map.values(bindings)
  defp binding_segments(bindings) when is_list(bindings), do: bindings
  defp binding_segments(other), do: [other]

  # ADR-043 §8 (T66) — "the kernel consumes it for grounding": auto-populate `:grounding`
  # from the D9 runtime catalog unless the caller already supplied one (explicit opt wins,
  # e.g. every T65 chokepoint test that passes its own `grounding:` directly). Catalog
  # computation is enrichment, never a security gate (that is the chokepoint's OWN §3.2
  # step-3 scrub, which covers `:grounding` too as of T65-F8's close) — `Samen.AI.Catalog.
  # grounding/2` itself never raises, so this can never turn a lookup hiccup into a blocked
  # completion.
  defp ensure_grounding(scope, opts) do
    if Keyword.has_key?(opts, :grounding) do
      opts
    else
      catalog_opts = Keyword.take(opts, [:domains, :resources])
      Keyword.put(opts, :grounding, Samen.AI.Catalog.grounding(scope, catalog_opts))
    end
  end
end
