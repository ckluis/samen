defmodule Samen.AI.Verbs do
  @moduledoc """
  Shared engine for the six ADR-043 §7.5 intelligence verbs (Summarize, Extract, Classify,
  Generate, Recommend, Analyze — the Prompt-resource remainder of the eight-verb D3
  surface; Search shipped as `Samen.AI.Embeddings.search/3` in T67). Each public per-verb
  module (`Samen.AI.Verbs.Summarize` etc.) is a THIN wrapper delegating `run/3` here.

  This module NEVER touches a `Samen.AI.Provider` callback and NEVER mints a
  `%Samen.AI.MaskedPayload{}` — every verb composes a prompt body (a built-in seed
  template, or an explicit org-scoped `Samen.AI.Prompt` name+version) plus caller-supplied
  input, then calls `Samen.AI.complete/4` (samen_core/lib/samen/ai.ex), which routes
  through `Samen.AI.Chokepoint.seal/3` + `complete/5`
  (samen_core/lib/samen/ai/chokepoint.ex) — the ONE egress chokepoint every AI-plane
  surface uses. `Samen.AI.ChokepointAntiBypassProbeTest`'s full-tree AST scan covers this
  file (and every verb file) exactly like any other `samen_core/lib` module: a
  `%MaskedPayload{}` construction here would flip it (RP-AI-1).

  ## Prompt resolution (`opts[:prompt]`, per §7.5 "verbs reference prompts by name +
  version")

    * omitted (default) — the verb's own BUILT-IN seed template
      (`Samen.AI.Prompt.samen_ai_prompt_template_bodies/0`), so a vertical gets a working
      verb at ≈0 authored LOC (framework-first, INV-5);
    * `{name, version}` — an EXPLICIT org-scoped `Samen.AI.Prompt` row via
      `Samen.AI.Prompt.fetch/3`, which reads through `Samen.Policy.OrgScope` like any
      other tenant read: a foreign org's prompt does not exist for this scope
      (`{:error, :not_found}`, never a cross-org leak);
    * `name` alone — the LATEST version of that name, same org-scoped lookup.

  ## Masked-path input (INV-1)

  `opts` is forwarded VERBATIM (minus the verb-only `:prompt`/`:params` keys) to
  `Samen.AI.complete/4`, which forwards to `Samen.AI.Chokepoint.seal/3` — so
  `opts[:bindings]` (a list of `{records, resource}` pairs) resolves a vault-routed field
  `••••`-masked on EVERY plane unless a live reveal grant + the `grant_plaintext_egress`
  host opt-in both apply (ADR-043 §6.1). `input`/`opts[:params]` are free text (§3.2 step
  2 — the caller's own keystrokes), rendered into the template BEFORE the chokepoint scrub,
  which still refuses any `vt_` sentinel they carry.
  """

  alias Samen.AI.Prompt

  @verbs [:summarize, :extract, :classify, :generate, :recommend, :analyze]

  @default_templates Map.new(Prompt.samen_ai_prompt_template_bodies())

  @doc "The six verb names this engine serves."
  @spec verbs() :: [atom()]
  def verbs, do: @verbs

  @doc """
  Run `verb` (one of `#{inspect(@verbs)}`) in `scope` over `input` (free text). `opts`:

    * `:prompt` — `{name, version}` | `name` | omitted (built-in default, see moduledoc)
    * `:params` — a map of extra `{{key}}` template substitutions (e.g. `%{labels: "a, b"}`)
    * everything else forwards to `Samen.AI.complete/4` (`:bindings`, `:provider`,
      `:grounding`, `:meta`, `:env_reader`, ...)

  Returns `{:ok, %Samen.AI.Completion{}}`, `{:error, :not_found}` (an explicit `:prompt`
  reference the scope's org cannot see), `{:error, :not_configured}` (keyless, fail-honest),
  or `{:error, :pii_egress_refused}` (the chokepoint scrub).
  """
  @spec run(atom(), term(), term(), keyword()) ::
          {:ok, Samen.AI.Completion.t()} | {:error, term()}
  def run(verb, scope, input, opts \\ []) when verb in @verbs do
    with {:ok, body} <- resolve_body(verb, scope, opts) do
      rendered = render(body, input, Keyword.get(opts, :params, %{}))
      complete_opts = Keyword.drop(opts, [:prompt, :params])
      Samen.AI.complete(scope, [rendered], %{}, complete_opts)
    end
  end

  # --- prompt resolution -------------------------------------------------------------------

  defp resolve_body(verb, scope, opts) do
    case Keyword.get(opts, :prompt) do
      nil -> default_body(verb)
      {name, version} -> fetch_body(scope, name, version)
      name when is_binary(name) or is_atom(name) -> fetch_body(scope, name, :latest)
    end
  end

  defp default_body(verb) do
    case Map.fetch(@default_templates, :"#{verb}_default") do
      {:ok, body} -> {:ok, body}
      :error -> {:error, {:no_default_template, verb}}
    end
  end

  defp fetch_body(scope, name, version) do
    case Prompt.fetch(scope, name, version) do
      {:ok, prompt} -> {:ok, prompt.body}
      {:error, _} = err -> err
    end
  end

  # --- rendering (free text, §3.2 step 2 — scrubbed by the chokepoint like any segment) ----

  defp render(body, input, params) do
    params
    |> Map.new()
    |> Map.put(:input, input)
    |> Enum.reduce(body, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end
end
