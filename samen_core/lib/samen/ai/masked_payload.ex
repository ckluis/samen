defmodule Samen.AI.MaskedPayload do
  @moduledoc """
  `%Samen.AI.MaskedPayload{}` — the **sealed, provider-bound value** of the AI plane
  (ADR-043 §3.2 step 4). This is the ONLY value a `Samen.AI.Provider` callback accepts
  at runtime (§3.2, the `VaultField.dump_to_native` clause-refusal mirror carried to the
  AI egress boundary): a provider's `complete/2` / `embed/2` pattern-match `%MaskedPayload{}`
  in the head, so a raw string/map cannot reach a provider at all — it refuses by
  `FunctionClauseError`.

  ## Single minting site (INV-7, D1)

  A `MaskedPayload` is minted by exactly ONE module: `Samen.AI.Chokepoint` (via its
  `seal/3`). No other module in `samen_core/lib` or `samen_web/lib` constructs the struct
  — a **detection guarantee** enforced at CI by `Samen.AI.ChokepointAntiBypassProbeTest`, an
  AST scan that flags a `MaskedPayload` constructed outside the chokepoint by ANY form: the
  `%MaskedPayload{...}` literal AND dynamic construction (`struct/2`, `struct!/2`,
  `Kernel.struct/2`, `apply(Kernel, :struct, ...)`, `%{__struct__: ...}`). It is NOT a
  compile-time type-impossibility — `%MaskedPayload{}` is a plain struct (`@enforce_keys
  [:kind]` only), so single-mint is enforced by the probe, not the type system; the honest
  residual is a determined metaprogramming path (fully-computed module name / runtime-generated
  code) beyond static AST detection. Combined with the provider clause-refusal, an
  accidental/refactor bypass (which a developer writes as one of the detected forms) is caught,
  and the sound value-layer INV-7 guarantee (PiiResolution egress mode → `%Masked{}`) is T65.

  T64 ships the TYPE + the seam + the adapter refusal. The full masking pipeline that
  produces the sealed `segments` from raw bindings (resolve → assemble → scrub) is T65
  (`Samen.AI.Chokepoint`'s resolve/scrub internals); T64's `seal/3` is the skeleton mint.

  ## Forge-resistance is NOT added — accepted-risk within the single-mint model (T138)

  A hand-forged `%MaskedPayload{}` carrying a `vt_*` string in a field is trusted uninspected
  by the chokepoint scrub allowlist (`safe_segment?/1`/`safe_metadata?/1` return `true` for a
  nested `%MaskedPayload{}`, since only `seal/3` is supposed to mint one). T138 evaluated
  adding a provenance guard (a per-VM/per-boot nonce, or an opaque tag stamped at `seal/3`
  mint time and re-checked at provider dispatch) so a payload not minted here would refuse.

  **Decision: no provenance guard — documented accepted-risk.** Any in-VM secret a forger
  could NOT read would have to live somewhere the forger's own code cannot reach; but a party
  able to construct `%MaskedPayload{}` in `lib/` already has arbitrary code execution in the
  same BEAM, so it can read any `:persistent_term`/module-attribute/process nonce and stamp a
  forgery identically. A provenance guard would therefore be **security theater against the
  in-VM threat** (it stops nothing an AST-clean forger cannot trivially defeat) while adding a
  fragile, always-on hot-path check to every dispatch. It buys no real boundary beyond what
  the single-mint discipline already gives.

  The REAL enforcement of single-mint is `Samen.AI.ChokepointAntiBypassProbeTest`
  (`test/chokepoint_anti_bypass_probe_test.exs`), the CI AST scan that flags a `MaskedPayload`
  construction (literal OR dynamic — `struct/2`, `struct!/2`, `%{__struct__: …}`, …) anywhere
  outside `Samen.AI.Chokepoint`. That, plus the provider clause-refusal (a raw string/map
  cannot reach a provider at all), is the shipped trust model: no in-repo code path lets an
  UNTRUSTED (external) caller construct a `%MaskedPayload{}` — every construction site is
  first-party `lib/` code the probe scans. The residual (runtime-computed metaprogramming
  beyond static AST detection, by code that already runs in-VM) is the same honest residual
  the moduledoc above names for single-mint. If a future code path ever lets an untrusted
  caller construct one, revisit this — a provenance tag becomes worth its cost only once the
  forger is OUTSIDE the VM's trust boundary.

  ## Inspect-redaction (EG6 — ADR-043 §3.2b, RP-AI-9)

  The observability shadow of an AI call is an egress path (log sinks are routinely
  third-party aggregators), so `%MaskedPayload{}` implements `Inspect` to REDACT its
  sealed segments — mirroring `%Samen.Masked{}`'s `#Masked<••••>`. A naive `inspect/1` in
  a log line (or a `Logger` `~p`) prints only the payload's kind + shape metadata
  (segment count, grounding-key names) — NEVER the segment content. So even sloppy
  observability code cannot spill an assembled prompt or grant-resolved plaintext.

  ## Fields

    * `:kind` — the egress class (`:complete` | `:embed` | `:mcp`); REQUIRED (`@enforce_keys`),
      so a construction always sets it (the anti-bypass probe keys on that — a field-bearing
      struct literal is a construction and appears only in the chokepoint; a field-less
      match is allowed everywhere). `:mcp` is the external-agent tool-response class (EG4;
      the MCP server proper is T69) — routed through the same scrub as `:complete`, but
      grants never apply to it (persisted/external egress, INV-7).
    * `:segments` — the sealed, already-scrubbed payload segments the provider transmits.
    * `:grounding` — catalog-derived grounding metadata (§8; metadata only, never sample
      values). A map keyed by bounded label atoms.
    * `:meta` — bounded, content-free dispatch metadata (payload id, size hints) safe for
      telemetry/logs.
  """

  @enforce_keys [:kind]
  defstruct kind: nil, segments: [], grounding: %{}, meta: %{}

  @type kind :: :complete | :embed | :mcp

  @type t :: %__MODULE__{
          kind: kind(),
          segments: [term()],
          grounding: map(),
          meta: map()
        }

  @doc "Is this value a sealed provider-bound payload? (structural guard for probes/tests)"
  @spec sealed?(term()) :: boolean()
  def sealed?(%__MODULE__{}), do: true
  def sealed?(_), do: false

  defimpl Inspect do
    import Inspect.Algebra

    # NEVER render the sealed segments — only bounded, content-free shape metadata
    # (EG6, ADR-043 §3.2b). Mirrors %Samen.Masked{}'s `#Masked<••••>` redaction.
    def inspect(%Samen.AI.MaskedPayload{} = payload, _opts) do
      # Field-less match + dot access on purpose: the single-mint anti-bypass probe keys on
      # a field-BEARING `%MaskedPayload{...}` construction literal, which must appear ONLY in
      # Samen.AI.Chokepoint — never here (this is redaction, not construction).
      seg_count = if is_list(payload.segments), do: length(payload.segments), else: 1
      grounding_keys = payload.grounding |> Map.keys() |> Enum.sort()

      concat([
        "#Samen.AI.MaskedPayload<",
        "kind: ",
        Kernel.inspect(payload.kind),
        ", segments: ",
        Integer.to_string(seg_count),
        " sealed, grounding: ",
        Kernel.inspect(grounding_keys),
        ">"
      ])
    end
  end
end
