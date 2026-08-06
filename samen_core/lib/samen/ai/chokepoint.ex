defmodule Samen.AI.Chokepoint do
  @moduledoc """
  THE single AI-egress chokepoint (ADR-043 §3; D2, T65 — the real masker; D1 seam was T64).
  This is the ONLY module in `samen_core`/`samen_web` that:

    1. **mints** a `%Samen.AI.MaskedPayload{}` (`seal/3` — the single-mint requirement,
       the `Samen.Files.ChokepointGuard` / `Samen.Delivery.Chokepoint` single-path
       mirror), and
    2. **invokes** a `Samen.AI.Provider` callback (`complete/5` / `embed/4` route to
       `provider.complete/2` / `provider.embed/2`).

  Both properties are DETECTED at CI (not compile-time-impossible):
  `Samen.AI.ChokepointAntiBypassProbeTest` is an AST scan over every app's `lib/` asserting no
  module outside this file constructs a `%Samen.AI.MaskedPayload{}` by ANY form. This is a
  detection guarantee (`%MaskedPayload{}` is a plain struct, so it is not type-impossible to
  forge); the honest residual is runtime-computed metaprogramming, beyond static AST detection.

  ## INV-7 by construction — the masking pipeline (§3.2), fail-CLOSED

  `seal/3` is a fixed-order pipeline; every step fails closed. It produces a
  `%MaskedPayload{}` ONLY after masking ALL vault-routed (🔒) content, or REFUSES with
  `{:error, :pii_egress_refused}` (payload-free — EG6):

    1. **Resolve** (§3.2 step 1) — every `:bindings` entry (`{records, resource}`) is resolved
       through `Samen.Api.PiiResolution.resolve/4` on the CALLER's actor in **egress mode**
       (`egress: true`): vault-routed fields come back `%Masked{}` (`••••`) on EVERY plane —
       masked-by-default (§6.1), stricter than the tenant UI. The ONE exception (INV-7's
       ephemeral clause): plaintext under a LIVE reveal grant AND the host opt-in
       `grant_plaintext_egress` (default off), admitted ONLY into a `:complete` payload —
       never `:embed`/`:mcp` (persisted/external egress; grants never apply). For `:embed`
       any vault-routed binding is REFUSED outright (deny-by-default, §7.2 — a vector persists
       beyond any grant window and is invertible; grants never unlock embedding).
    2. **Re-scrub history** (§3.2a) — `:history` (prior turns, INCLUDING prior assistant
       output) re-enters only here, re-resolved against the CURRENT turn's grant state. A
       grant-tagged span (`{:grant_span, text, %Samen.Reveal.Context{}}`) that the current
       turn no longer covers (grant lapsed/revoked, actor changed, or the flag now off)
       **re-masks to `••••` before assembly** — accumulated history cannot carry plaintext
       past its grant window into an ungranted turn. A grant-tagged span the current turn
       cannot VALIDATE is treated identically: a span whose context is not a
       `%Samen.Reveal.Context{}` (or whose grant checker raises) is un-re-checkable, so it
       re-masks — keeping the prior turn's plaintext because the tag was unparseable is the
       fail-OPEN reading §3.2a forbids.
    3. **Assemble** — `segments ++ resolved-binding-segments ++ re-scrubbed-history`.
    4. **Scrub-refuse** (§3.2 step 3) — the fully-assembled payload is scanned by an
       **allowlist** (`unsafe_segment?/1` = "not provably safe"): a segment egresses ONLY if
       it is a `vt_`-free binary, a bounded primitive (number / boolean / `nil`), an
       already-sealed `%MaskedPayload{}`, or a list of such. EVERY other shape — a tuple, a
       keyword list, a map, a struct (`%Samen.Masked{}` / `%Ash.ForbiddenField{}`, a
       still-un-rendered record), an atom, a pid — is unsafe BY CONSTRUCTION ⇒
       `{:error, :pii_egress_refused}`. The inversion is load-bearing: a blocklist of "bad"
       shapes fails OPEN for every shape nobody thought of (a raw `vt_*` token wrapped in an
       EG2 tool-args tuple/keyword/map used to pass), so the predicate enumerates what is
       provably safe and refuses the rest. **Refuse, never silently strip** (the WriteGuard
       posture: a rejected write leaves the wire provably untouched). Free text (user
       keystrokes — a chat question, a draft instruction) is NOT a vault-routed value, so a
       `vt_`-free string passes this scrub (INV-7 governs vault-routed values, not consented
       keystrokes — §3.2 step 2). The operator-responsibility boundary of that free-text
       admission is §7.2.
    5. **Seal** (§3.2 step 4) — mint `%MaskedPayload{}`. The provider boundary accepts ONLY
       this value (runtime clause refusal + the AST single-mint probe).

  ## Why an unmasked prompt cannot reach a provider (the token-blind argument, §3.3)

  The assembling path never POSSESSES unauthorized plaintext: PiiResolution in egress mode
  returns `%Masked{}` (token + label, zero plaintext — "there is no plaintext to leak by any
  serialization path"), and plaintext exists only when a live grant + the host opt-in resolved
  it through the one sanctioned decrypt site. Even a hostile assembler that obtained a `vt_*`
  token finds the scrub refusing it; even code that skips the chokepoint finds no provider
  callback willing to take its string.

  ## EG6 — masked observability by construction (§3.2b, RP-AI-9)

    * `{:error, :pii_egress_refused}` is payload-free: it never embeds the offending segment
      or value — diagnostic context is identifiers only.
    * Adapter errors are NORMALIZED before they propagate (`normalize_error/2`): a raised
      exception or a rich `{:error, term()}` is reduced to a content-free
      `{:provider_error, provider}` — no adapter error can carry the assembled prompt or
      grant-resolved plaintext.
    * `%Samen.AI.MaskedPayload{}` is Inspect-redacting, so a naive log line cannot spill it.

  ## Grounding/meta scrub (T65-F8 close — ADR-043 §3.1 EG1 / §3.2 step 3, T66)

  `:grounding` and `:meta` are EG1 payload fields too ("completion prompts (system +
  GROUNDING + context + user segments)", §3.1), so `seal/3` scrubs them with the SAME
  fail-closed-allowlist principle as `segments` — a bounded-map generalization of
  `safe_segment?/1` (`safe_metadata?/1`, below), not a bespoke second scrub. A `vt_*`-carrying
  or unresolved-vault-field value inside `:grounding`/`:meta` refuses `{:error,
  :pii_egress_refused}` exactly like a `segments` violation, before T66 makes grounding LIVE
  (the D9 runtime catalog, `Samen.AI.Catalog`).

  ## Deferred (per ADR-043 §11)

  T67 fills the embeddings plane (the `Samen.AI.Embedder.Deterministic`, pgvector, the
  embeddable-field allowlist DSL — this chokepoint already REFUSES a vault-routed embed
  input fail-closed). T69 fills the MCP server on the `:mcp` seam. T72 EXTENDS the permanent
  red-team (more adversarial cases + full-DB canary seeding); T65 establishes the tier.
  """

  alias Samen.AI.Completion
  alias Samen.AI.MaskedPayload
  alias Samen.Api.PiiResolution
  alias Samen.Pii.Info
  alias Samen.Reveal

  @refusal {:error, :pii_egress_refused}

  # The vault FK-token sentinel (`vt_*`; `Samen.Vault.generate_token/0` mints `"vt_" <> 32hex`).
  # Its presence ANYWHERE in a rendered segment means a raw token bypassed resolution (§3.2
  # step 3). We refuse on the PREFIX substring, not the anchored `^vt_[0-9a-f]{32}$` form —
  # the most fail-closed reading: a token embedded mid-string (e.g. a laundered
  # `"...vt_deadbeef..."`) must also be refused, not just a standalone token.
  @vt_sentinel "vt_"

  @mask Samen.Masked.mask()

  @doc """
  Mint a `%Samen.AI.MaskedPayload{}` — the ONE minting site (ADR-043 §3.2 step 4), fail-CLOSED.

  Runs the full masking pipeline (moduledoc): resolve `:bindings` in egress mode → re-scrub
  `:history` → assemble → scrub-refuse → seal. Returns `{:ok, %MaskedPayload{}}` only after
  ALL vault-routed content is masked, else `{:error, :pii_egress_refused}` (payload-free).

  `kind` is `:complete | :embed | :mcp`.

  ## Options (the egress context — ADR-043 §3.2)

    * `:actor` / `:scope` — the caller's actor, threaded to `PiiResolution.resolve/4` (egress
      mode). Absent ⇒ the nil-plane default (masked; never plaintext).
    * `:bindings` — `[{records, resource}]` vault-routed record bindings to resolve+mask in
      egress mode. Each resolved vault field renders `••••` (or grant-plaintext for
      `:complete` under the flag). For `:embed`, a vault-routed binding is REFUSED (§7.2).
    * `:grant_egress?` — host opt-in override; defaults to the config flag
      `config :samen_core, Samen.AI, grant_plaintext_egress: <bool>` (default `false`).
      Effective for `:complete` only.
    * `:grant`, `:repo`, `:vault` — passed through to `PiiResolution.resolve/4` (grant-checker
      / vault-repo / vault-module injection — tests inject an approving grant here).
    * `:history` — prior-turn segments (strings, or `{:grant_span, text, %Reveal.Context{}}`
      for grant-tagged spans re-checked per §3.2a).
    * `:grounding` (metadata map) and `:meta` (bounded dispatch metadata).
  """
  @spec seal(MaskedPayload.kind(), [term()] | term(), keyword()) ::
          {:ok, MaskedPayload.t()}
          | {:error, :pii_egress_refused | :invalid_grounding_shape}
  def seal(kind, segments, opts \\ []) when kind in [:complete, :embed, :mcp] do
    grounding = Keyword.get(opts, :grounding, %{})
    meta = Keyword.get(opts, :meta, %{})

    with {:ok, binding_segs} <- resolve_bindings(kind, opts),
         {:ok, history_segs} <- rescrub_history(kind, opts),
         {:ok, assembled} <- assemble_and_scrub(segments, binding_segs, history_segs),
         :ok <- scrub_metadata(grounding),
         :ok <- scrub_metadata(meta) do
      {:ok,
       %MaskedPayload{
         kind: kind,
         segments: assembled,
         grounding: grounding,
         meta: meta
       }}
    end
  end

  @doc """
  Seal `segments` and dispatch to `provider.complete/2` — the ONE provider-invocation site
  for completions. Any adapter error is normalized (EG6) before it propagates.
  """
  @spec complete(module(), map(), MaskedPayload.kind(), [term()] | term(), keyword()) ::
          {:ok, Samen.AI.Completion.t()} | {:error, term()}
  def complete(provider, config, kind, segments, opts \\ []) when is_atom(provider) do
    with {:ok, %MaskedPayload{} = payload} <- seal(kind, segments, opts) do
      dispatch(provider, :complete, payload, config)
    end
  end

  @doc """
  Seal `segments` and dispatch to `provider.embed/2` — the ONE provider-invocation site for
  embeddings. (The embeddings plane proper — pgvector, the deterministic embedder, the
  embeddable-field allowlist — is T67; this is the kernel seam it routes through. A
  vault-routed embed input is REFUSED here fail-closed, §7.2.)
  """
  @spec embed(module(), map(), [term()] | term(), keyword()) ::
          {:ok, [[float()]]} | {:error, term()}
  def embed(provider, config, segments, opts \\ []) when is_atom(provider) do
    with {:ok, %MaskedPayload{} = payload} <- seal(:embed, segments, opts) do
      dispatch(provider, :embed, payload, config)
    end
  end

  # --- step 1: resolve vault-routed bindings in egress mode ------------------------------

  # Returns {:ok, [rendered_segment]} or a fail-closed refusal.
  defp resolve_bindings(kind, opts) do
    bindings = opts |> Keyword.get(:bindings, []) |> List.wrap()
    actor = Keyword.get(opts, :actor) || Keyword.get(opts, :scope)
    grant_egress? = grant_egress?(kind, opts)

    resolve_opts =
      opts
      |> Keyword.take([:repo, :vault, :grant])
      |> Keyword.put(:egress, true)
      |> Keyword.put(:grant_egress?, grant_egress?)

    Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, acc} ->
      case resolve_binding(kind, binding, actor, resolve_opts) do
        {:ok, segs} -> {:cont, {:ok, acc ++ segs}}
        @refusal -> {:halt, @refusal}
      end
    end)
  end

  defp resolve_binding(kind, {records, resource}, actor, resolve_opts) when is_atom(resource) do
    records = List.wrap(records)

    cond do
      # A binding is an explicit `{records, resource}` pair whose resource is a REAL
      # PII-introspectable resource and whose records are structs OF that resource. Anything
      # else is an assembler bug: REFUSE (payload-free), never guess and never RAISE. A raise
      # is fail-safe for the wire but is NOT the contract, and an exception message/stack
      # trace is itself an EG6 egress (§3.2b) — `{[], nil}` / `{[], Enum}` used to raise
      # `ArgumentError` out of `Samen.Pii.Info`.
      not pii_resource?(resource) ->
        @refusal

      not Enum.all?(records, &is_struct(&1, resource)) ->
        @refusal

      true ->
        pii_fields = resource |> Info.pii_attributes() |> Enum.map(& &1.name)

        # Deny-by-default for embeddings (ADR-043 §7.2): a vault-routed field must never enter
        # vector space — not even under a grant. Refuse fail-closed rather than mask (a masked
        # `••••` vector is useless AND the refusal exposes the misuse).
        #
        # T135 (T67 close): key the runtime `:embed` deny on the SAME UNION the structural
        # verifier keys on — `Samen.Pii.Info.pii_attributes/1` (logical names) ∪
        # `vault_routed_columns/1` (physical storage names) — so runtime and structural agree
        # BY CONSTRUCTION rather than by the fact that the two halves happen to be co-empty
        # (both derive from the `pii do` block). If a future field is ever vault-routed via a
        # path that surfaces in `vault_routed_columns/1` but not `pii_attributes/1`, this still
        # refuses. Behaviorally identical today (the halves are co-empty); the alignment is the
        # point (`mix samen.verify.ai_prompt_masking` (b) reads exactly this union).
        vault_routed? = pii_fields != [] or Info.vault_routed_columns(resource) != []

        if kind == :embed and vault_routed? do
          @refusal
        else
          resolved = PiiResolution.resolve(records, resource, actor, resolve_opts)
          {:ok, Enum.flat_map(resolved, fn rec -> render_fields(rec, pii_fields) end)}
        end
    end
  rescue
    # Belt to the braces of the shape validation above: NO adversarial binding escapes this
    # chokepoint as an exception. Any unexpected raise degrades to the payload-free refusal.
    _ -> @refusal
  end

  # A binding must be an explicit {records, resource} pair — anything else is an assembler bug;
  # refuse rather than guess (fail-closed).
  defp resolve_binding(_kind, _other, _actor, _opts), do: @refusal

  # Is `resource` a module whose vault-routed fields we can introspect? `Spark.Dsl.Extension`
  # RAISES on a non-DSL module, so this is the fail-closed pre-check (allowlist), not a rescue.
  defp pii_resource?(resource) do
    not is_nil(resource) and Ash.Resource.Info.resource?(resource)
  end

  # Render each resolved vault field to a wire-safe segment: `%Masked{}` / `%Ash.ForbiddenField{}`
  # → `"••••"`; a grant-resolved plaintext string passes through (the one permitted egress).
  defp render_fields(record, pii_fields) do
    Enum.map(pii_fields, fn name -> render_value(Map.get(record, name)) end)
  end

  defp render_value(%Samen.Masked{}), do: @mask
  defp render_value(%Ash.ForbiddenField{}), do: @mask
  defp render_value(nil), do: @mask
  defp render_value(other), do: other

  # --- step 2: multi-turn history re-scrub (§3.2a) ---------------------------------------

  defp rescrub_history(kind, opts) do
    history = opts |> Keyword.get(:history, []) |> List.wrap()
    grant_egress? = grant_egress?(kind, opts)
    grant_mod = Keyword.get(opts, :grant, Reveal.grant_checker())

    segs =
      Enum.map(history, fn
        # A grant-tagged span from an earlier turn (§3.2a): keep the plaintext ONLY if the
        # CURRENT turn still covers it (flag on AND the grant re-approves the exact context).
        # Otherwise RE-MASK — an expired/revoked/actor-changed/flag-off turn cannot echo it.
        {:grant_span, _text, %Reveal.Context{} = ctx} = span ->
          if grant_egress? and granted?(grant_mod, ctx), do: span_text(span), else: @mask

        # A MALFORMED grant-tagged span: the tag claims grant-resolved plaintext but the
        # context is NOT a `%Reveal.Context{}`, so THIS turn cannot re-check the grant that
        # admitted it. Un-re-checkable ⇒ RE-MASK (§3.2a fail-closed). Retaining the prior
        # turn's plaintext because the tag was unparseable is the fail-OPEN reading.
        {:grant_span, _text, _ctx} ->
          @mask

        # Any other history entry is treated as an ordinary segment — scrubbed for
        # `vt_`/`%Masked{}` by step 4 like any segment.
        other ->
          other
      end)

    {:ok, segs}
  end

  defp span_text({:grant_span, text, _ctx}), do: text

  # The grant checker is host-injected (`:grant`), so it is adversarial input too: a missing /
  # non-conforming / raising checker must not become an egress. Anything but a literal `true`
  # — including an exception — is NOT granted, so the span re-masks (§3.2a fail-closed).
  defp granted?(grant_mod, ctx) do
    grant_mod.granted?(ctx) == true
  rescue
    _ -> false
  end

  # --- grant gating ----------------------------------------------------------------------

  # The `grant_plaintext_egress` gate (ADR-043 §6.1): effective ONLY for `:complete` (the
  # ephemeral egress), and default OFF. `:embed`/`:mcp` never admit grant plaintext (INV-7).
  defp grant_egress?(:complete, opts) do
    Keyword.get_lazy(opts, :grant_egress?, fn -> config_grant_egress?() end)
  end

  defp grant_egress?(_kind, _opts), do: false

  defp config_grant_egress? do
    Application.get_env(:samen_core, Samen.AI, [])
    |> Keyword.get(:grant_plaintext_egress, false)
  end

  # --- the single provider-invocation site -----------------------------------------------

  defp dispatch(provider, :complete, %MaskedPayload{} = payload, config) do
    provider.complete(payload, config)
  rescue
    e -> {:error, normalize_error(e, provider)}
  else
    # Stamp `:simulated` BY CONSTRUCTION from the dispatched provider (T152) — the ONE
    # provider-invocation site is the honest place to decide it, never the completion
    # `:text`. A keyless/deterministic double declares itself simulated via the optional
    # `simulated?/0` callback; a live adapter that omits it is treated as live (`false`).
    {:ok, %Completion{} = c} -> {:ok, %{c | simulated: simulated_provider?(provider)}}
    {:ok, _} = ok -> ok
    {:error, reason} -> {:error, normalize_error(reason, provider)}
    other -> {:error, normalize_error(other, provider)}
  end

  defp dispatch(provider, :embed, %MaskedPayload{} = payload, config) do
    provider.embed(payload, config)
  rescue
    e -> {:error, normalize_error(e, provider)}
  else
    {:ok, _} = ok -> ok
    {:error, reason} -> {:error, normalize_error(reason, provider)}
    other -> {:error, normalize_error(other, provider)}
  end

  # EG6 (§3.2b): an adapter error must not carry outbound payload content. A bounded atom
  # reason (`:not_configured`, `:not_implemented`, …) is safe and passes through; anything
  # richer (a tuple/struct/exception that could echo a prompt) is reduced to a content-free
  # `{:provider_error, provider}`.
  defp normalize_error(reason, _provider) when is_atom(reason), do: reason
  defp normalize_error(_reason, provider), do: {:provider_error, provider}

  # Is the dispatched provider a SIMULATED (keyless/deterministic) double? (T152.) Read the
  # provider's OWN optional `simulated?/0` declaration — a provider that omits it is LIVE
  # (fail-honest default: only an explicitly-simulated provider is stamped `true`). Wrapped
  # so a provider whose `simulated?/0` raises can never turn a successful completion into a
  # crash — it degrades to `false` (the same EG6-safe posture as the dispatch itself).
  defp simulated_provider?(provider) do
    Code.ensure_loaded?(provider) and function_exported?(provider, :simulated?, 0) and
      provider.simulated?() == true
  rescue
    _ -> false
  end

  # --- steps 3+4: assemble + the scrub (fail-CLOSED by ALLOWLIST) -------------------------

  defp assemble_and_scrub(segments, binding_segs, history_segs) do
    assembled = List.wrap(segments) ++ binding_segs ++ history_segs

    if Enum.any?(assembled, &unsafe_segment?/1), do: @refusal, else: {:ok, assembled}
  rescue
    # Traversing an adversarial term (an improper list, a term whose enumeration raises) must
    # REFUSE, never raise — a crash is not the contract, and its stack trace is an EG6 egress.
    _ -> @refusal
  end

  # THE scrub predicate (§3.2 step 3), stated as the NEGATION of an allowlist. This inversion
  # is the whole fail-closed property: a blocklist of "bad" shapes silently admits every shape
  # nobody enumerated — the pre-fix predicate fell through to `false` (= safe) for tuples,
  # keyword lists and maps, so a RAW `vt_*` token wrapped in an EG2 tool-args tuple
  # (`{:account_token, "vt_…"}`) egressed to the provider, breaching INV-7. Now a segment
  # egresses only if it is PROVABLY safe, and everything unrecognized REFUSES.
  defp unsafe_segment?(seg) do
    not safe_segment?(seg)
  rescue
    # Un-inspectable / adversarial term ⇒ unsafe (fail-closed), never a raise.
    _ -> true
  end

  # The allowlist of provably-safe, already-rendered wire shapes:
  #
  #   * a binary carrying no `vt_` sentinel — the rendered form of every legitimate segment
  #     (free text, `••••`, a grant-resolved plaintext string);
  #   * a bounded primitive (number / boolean / `nil`) — renders to a fixed literal, cannot
  #     carry a vault value;
  #   * an already-sealed `%MaskedPayload{}` — minted by THIS module, so already scrubbed;
  #   * a list whose every element is safe AND whose charlist rendering carries no sentinel.
  #
  # Everything else — tuple, keyword list, map, ANY other struct (`%Samen.Masked{}`,
  # `%Ash.ForbiddenField{}`, an un-rendered record, a composite vault value), atom, pid, ref,
  # fun — is NOT provably safe and therefore refuses. Rendering is the assembler's job; an
  # un-rendered shape at the scrub is exactly the "binding that bypassed step 1" case.
  defp safe_segment?(seg) when is_binary(seg), do: not String.contains?(seg, @vt_sentinel)
  defp safe_segment?(seg) when is_number(seg) or is_boolean(seg) or is_nil(seg), do: true
  defp safe_segment?(%MaskedPayload{}), do: true

  defp safe_segment?(seg) when is_list(seg) do
    Enum.all?(seg, &safe_segment?/1) and not charlist_sentinel?(seg)
  end

  defp safe_segment?(_other), do: false

  # A charlist's ELEMENTS are all safe integers, but its rendering can carry the sentinel
  # (`~c"vt_dead…"`), so scan the rendering too.
  defp charlist_sentinel?(seg) do
    List.ascii_printable?(seg) and String.contains?(List.to_string(seg), @vt_sentinel)
  end

  # --- grounding/meta scrub (ADR-043 §3.1 EG1 "grounding" / §3.2 step 3, T65-F8 close) ---
  #
  # T65's fix-round verifier LIVE-REPRODUCED a shape-blindness hole one field over from F1:
  # `seal/3` scrubbed `segments` but copied `:grounding`/`:meta` into the sealed payload with
  # NO allowlist, NO vt_ scan, and NO resolution —
  # `Chokepoint.complete(Fake, %{}, :complete, ["ok"], grounding: %{table: "vt_aaa…", sample:
  # "<canary>"})` egressed the canary verbatim. ADR-043 §3.1 lists EG1 as "completion prompts
  # (system + GROUNDING + context + user segments)" and §3.2 step 3 says "the fully rendered
  # payload is scanned" — grounding/meta ARE governed EG1 surface, not a side channel. T66
  # makes grounding LIVE (the D9 runtime catalog), so this closes the hole before it does.
  #
  # `:grounding`/`:meta` are CONTRACTUALLY maps (`Samen.AI.MaskedPayload` doc: "a map keyed by
  # bounded label atoms"), unlike `segments` (pre-rendered flat text) — so they cannot be
  # scrubbed by `safe_segment?/1` UNCHANGED: that predicate refuses EVERY map, by design (F1 /
  # sabotage 45 proved a values-only map scan is unsound because it never inspects KEYS, so a
  # `vt_*` token smuggled into a map key would slip a values-only scan). `safe_metadata?/1`
  # below is the SAME fail-closed-allowlist principle, generalized to the shape grounding/meta
  # actually have: every leaf scalar case DELEGATES to `safe_segment?/1` (no independently
  # invented rules); the only NEW cases are the map/list recursion, and — because grounding
  # keys ARE "bounded label atoms" by contract (e.g. `%{table: :accounts}`, the shape every
  # shipped test already uses) — atoms are allowed here (unlike in `segments`, where an atom
  # is not provably safe because a segment is never legitimately an atom).
  #
  # `nil` / `[]` are the natural "no grounding" — a caller who has nothing to ground with
  # (e.g. `grounding: []`, the empty default before a host wires a catalog) is NOT attempting a
  # PII egress, so accept them as empty rather than crying wolf with the `:pii_egress_refused`
  # SECURITY error. Matched ABOVE the scalar/map clauses so an empty list is "no metadata"
  # (there are no leaves to scan), never a shape error.
  defp scrub_metadata(nil), do: :ok
  defp scrub_metadata([]), do: :ok

  # A NON-map, NON-empty scalar/list (`grounding: "x"`, `42`, `:atom`, `~c"…"`, `["a"]`) does not
  # match the documented `%Samen.AI.MaskedPayload{}` contract ("a map keyed by bounded label
  # atoms"). That is a SHAPE problem, not a leak — return a DISTINCT `:invalid_grounding_shape`
  # so a caller is not misled into a PII-leak investigation over a wrong-typed field. This does
  # NOT weaken the scrub: the value still runs through `unsafe_metadata?/1` first, so a
  # `vt_*`/`%Masked{}` sentinel smuggled in as a bare term (e.g. a top-level `~c"vt_…"` charlist)
  # STILL refuses `:pii_egress_refused` — the SECURITY refusal wins over the shape error, and the
  # T65-F8 / T66-F1 red-team legs (sabotages 46/47) stay refutable here.
  defp scrub_metadata(value)
       when is_binary(value) or is_number(value) or is_atom(value) or is_list(value) do
    if unsafe_metadata?(value), do: @refusal, else: {:error, :invalid_grounding_shape}
  rescue
    _ -> @refusal
  end

  # T66-F1 fix-round (delta-verifier finding): the TOP-LEVEL value must itself be a map — a
  # non-map `:grounding`/`:meta` (a bare string, a charlist, a number, …) does not match the
  # documented contract, so it refuses fail-closed here rather than falling through to
  # `safe_metadata?/1`'s scalar leaf cases (which exist to scrub VALUES/KEYS *inside* an
  # already-map-shaped grounding/meta, not to bless a non-map top level).
  defp scrub_metadata(value) when is_map(value) do
    if unsafe_metadata?(value), do: @refusal, else: :ok
  rescue
    _ -> @refusal
  end

  defp scrub_metadata(_value), do: @refusal

  defp unsafe_metadata?(seg) do
    not safe_metadata?(seg)
  rescue
    # Un-inspectable / adversarial term ⇒ unsafe (fail-closed), never a raise.
    _ -> true
  end

  # A previously-sealed payload is trusted whole (already scrubbed by this module).
  defp safe_metadata?(%MaskedPayload{}), do: true
  # Any OTHER struct (DateTime, an un-rendered Ash record, %Samen.Masked{}, …) is NOT
  # provably safe — checked before the generic `is_map/1` clause below, since a struct IS a
  # map under the hood and must not be treated as a plain key/value bag.
  defp safe_metadata?(seg) when is_struct(seg), do: false

  # A plain map: BOTH keys and values must recurse through this predicate — the fix for the
  # values-only scan F1 closed for `segments`. The catalog dict's JSON-ish shape
  # (`%{"table_name" => ..., "fields" => [%{...}]}`) is exactly a nested map/list of binaries
  # and booleans, so this recurses all the way down to the vt_-scanned leaves.
  defp safe_metadata?(seg) when is_map(seg) do
    Enum.all?(seg, fn {k, v} -> safe_metadata?(k) and safe_metadata?(v) end)
  end

  # T66-F1 fix-round (delta-verifier finding, HIGH — fail-open): this clause DROPPED the
  # `charlist_sentinel?/1` check `safe_segment?/1`'s own list clause carries, so
  # `grounding: %{sample: ~c"vt_aaa…"}` sealed with the raw token intact (a charlist's
  # ELEMENTS are safe integers, but its RENDERING can carry the sentinel — the exact case
  # `charlist_sentinel?/1` exists for). Added back so grounding/meta is leaf-for-leaf at
  # least as strict as the segment scrub, per the moduledoc's own "delegates to
  # `safe_segment?/1` verbatim" claim.
  defp safe_metadata?(seg) when is_list(seg) do
    Enum.all?(seg, &safe_metadata?/1) and not charlist_sentinel?(seg)
  end

  # A bounded label atom (`:table`, `:accounts`, `true`/`false`/`nil` — all atoms in Elixir)
  # is allowed here (grounding's contractual shape), scanned on its RENDERED name for the
  # sentinel — the same fail-closed reading `charlist_sentinel?/1` applies to a charlist.
  defp safe_metadata?(seg) when is_atom(seg) do
    not (seg |> Atom.to_string() |> String.contains?(@vt_sentinel))
  rescue
    _ -> false
  end

  # Every other leaf shape (binary, number, boolean/nil already caught above as atoms, pid,
  # ref, fun) delegates to the segments allowlist verbatim — no independently invented rule.
  defp safe_metadata?(seg), do: safe_segment?(seg)
end
