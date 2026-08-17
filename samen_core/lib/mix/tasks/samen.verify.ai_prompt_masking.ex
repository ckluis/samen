defmodule Mix.Tasks.Samen.Verify.AiPromptMasking do
  @shortdoc "INV-7 structural gate: no vault-routed field is embeddable; no Prompt body carries a vt_ token."

  @moduledoc """
  `mix samen.verify.ai_prompt_masking` — the D2 verifier tier (ADR-043 §3.4, T65). The
  **structural** half of the `ai_prompt_masking` gate that proves INV-7 (no-PII-egress); the
  **runtime** half is the permanent canary red-team ExUnit suite
  (`samen_core/test/ai/ai_prompt_masking_test.exs`, RP-AI-9/10), which runs under the
  `samen_core` `mix test` gate and asserts a seeded PII canary NEVER appears at any egress
  class EG1–EG6 (prompt, tool args, embedding, MCP, grounding, and the EG6 log/telemetry/error
  shadow), sabotage-refutable.

  This task mirrors the house verifier shape (`run/1` → `Samen.Verifier.halt_if_violations/2`;
  `violations/1` callable without halting) and is wired into the demo/vertical `ci.sh` step
  lists + the `ci_sh.eex` generator template + the root gate.

  ## What it checks (the persisted-egress structural invariants — §3.4)

    * **(b) no vault-routed field is embeddable** (§7.2): a resource that declares an
      embeddable field (the T67 `embeddable_fields/0` seam) whose column is vault-routed
      (`Samen.Pii.Info.vault_routed_columns/1`) or catalog-flagged `pii: true` is a violation
      — a vector persists beyond any grant window and is invertible, so vault-routed values
      must never enter vector space (grants never unlock embedding). The chokepoint ALSO
      refuses such an input fail-closed at runtime; this is the compile-time backstop.
    * **(c) no Prompt-resource template body carries a `vt_` sentinel** (§7.5): a managed
      Prompt template (the T68 `samen_ai_prompt_template_bodies/1` seam) whose body contains a
      `vt_` vault-token sentinel is a violation — a committed template must never embed a raw
      vault FK token (EG5, authored-under-the-same-scrub).

  T67 (embeddings plane) lands the `embeddable_fields/0` declaration and T68 lands the Prompt
  resource, at which point (b)/(c) become non-vacuous on real resources; the seams are read
  defensively here so the gate is green-and-real today and binds automatically as those tasks
  ship. The load-bearing INV-7 proof for T65 is the runtime red-team.
  """

  use Mix.Task

  @task_name "samen.verify.ai_prompt_masking"

  # A vault FK token sentinel (`Samen.Vault.generate_token/0` mints `"vt_" <> 32 hex`). A
  # Prompt body must never contain one; refuse on the prefix (most fail-closed).
  @vt_sentinel "vt_"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _rest, _} = OptionParser.parse(args, strict: [domain: :keep])
    Samen.Verifier.halt_if_violations(@task_name, violations(opts))
  end

  @doc """
  Compute the INV-7 structural violations (list of human-readable strings), without halting —
  the test-callable seam.
  """
  @spec violations(keyword()) :: [String.t()]
  def violations(opts \\ []) do
    resources = opts |> domains() |> Enum.flat_map(&Ash.Domain.Info.resources/1) |> Enum.uniq()

    embeddable_vault_violations(resources) ++
      prompt_body_vt_violations(resources) ++
      tool_schema_boundedness_violations() ++
      tool_eligibility_violations()
  end

  # --- (d) tool-schema boundedness + staticness (ADR-047 §7.2 check (d)) ------------------

  @doc """
  The (d) cross-check over the opted-in agent-tool modules (public for the unit test).

  Every `Samen.AI.Agent` tool definition (`tool_schema/0`) is EG2 egress on every turn, so
  it must be a BOUNDED, STATIC, `vt_`-free constant:

    * **boundedness** — the returned map's leaves (keys AND values, recursively) are only
      binaries / atoms / numbers / booleans; a struct, pid, fun, or nested tenant term is a
      violation. No leaf contains a `vt_` vault-token sentinel;
    * **staticness** — the `tool_schema/0` body carries no call into `Ash`/`Repo`/
      `Application.get_env` (a schema populated from live records is a silent EG2 egress of
      tenant data on every turn — ADR-047 §4.2's load-bearing static-schema rule).
  """
  @spec tool_schema_boundedness_violations() :: [String.t()]
  def tool_schema_boundedness_violations do
    for mod <- tool_modules(), violation <- tool_schema_violations(mod), do: violation
  end

  defp tool_schema_violations(mod) do
    schema = safe(fn -> mod.tool_schema() end, :not_a_tool)

    bounded =
      cond do
        not (is_map(schema) and not is_struct(schema)) ->
          ["#{inspect(mod)}: `tool_schema/0` did not return a bounded map (got " <>
             "#{inspect(schema)}) — a tool def is EG2 egress and must be a static map (§4.2)."]

        not bounded_term?(schema) ->
          ["#{inspect(mod)}: `tool_schema/0` carries a non-bounded leaf (a struct / pid / " <>
             "fun / rich term) — every EG2 tool-def leaf must be a binary/atom/number/" <>
             "boolean (ADR-047 §4.2)."]

        vt_in_term?(schema) ->
          ["#{inspect(mod)}: `tool_schema/0` embeds a `vt_` vault-token sentinel — a tool " <>
             "definition must never carry a raw vault FK token (INV-7 / ADR-047 §4.2)."]

        true ->
          []
      end

    bounded ++ tool_schema_staticness_violations(mod)
  end

  # Staticness — an AST scan of the module's own source (its compile-time path): the
  # `tool_schema/0` body may not call into Ash/Repo/Application (tenant-data reads). If the
  # source is unreadable, this is inert (green-and-real), like the other defensive seams.
  defp tool_schema_staticness_violations(mod) do
    with path when is_binary(path) <- source_path(mod),
         true <- File.regular?(path),
         {:ok, ast} <- Code.string_to_quoted(File.read!(path), emit_warnings: false),
         body when not is_nil(body) <- tool_schema_body(ast, mod) do
      if dynamic_call?(body) do
        ["#{inspect(mod)}: `tool_schema/0` calls into Ash/Repo/Application — a schema derived " <>
           "from tenant data is a silent EG2 egress on every turn; it MUST be a compile-time " <>
           "constant (ADR-047 §4.2's static-schema rule)."]
      else
        []
      end
    else
      _ -> []
    end
  end

  # --- (e) tool eligibility (ADR-047 §7.2 check (e)) -------------------------------------

  @doc """
  The (e) eligibility cross-check (public for the unit test):

    * every opted-in tool module also exports `effect/0` (`:read | :write`);
    * `"webhook"` and any analytics action are NOT opt-in eligible (arbitrary model-chosen
      egress / an always-refused T144 surface — ADR-047 §5.1, named so no one adds them).

  (The "every agent's `tools:` ⊆ opted-in registry" arm of §7.2 check (e) lives in
  `mix samen.verify.agent_coverage`, which parses agent definitions from lib/ SOURCE — a
  runtime module enumeration here would false-positive on the deliberately-adversarial agent
  test fixtures. The property is ALSO enforced fail-closed at run start by
  `Samen.AI.Agent.Tools.resolve_definition/1`.)
  """
  @spec tool_eligibility_violations() :: [String.t()]
  def tool_eligibility_violations do
    effect_violations() ++ excluded_tool_violations()
  end

  defp effect_violations do
    for mod <- tool_modules(), not exports?(mod, :effect, 0) do
      "#{inspect(mod)}: an opted-in agent tool does not export `effect/0` — every tool must " <>
        "declare its `:read | :write` class explicitly (ADR-047 §5.1)."
    end
  end

  # `"webhook"` (arbitrary model-chosen URL egress — a new egress class v1 does not govern)
  # and any analytics action MUST NOT be opt-in eligible.
  defp excluded_tool_violations do
    opted_in = MapSet.new(Samen.Automation.Action.tool_kinds())

    excluded =
      for kind <- Samen.Automation.Action.kinds(),
          kind == "webhook" or String.contains?(kind, "analytics"),
          MapSet.member?(opted_in, kind) do
        "the excluded-by-rule action #{inspect(kind)} is opted in as an agent tool — " <>
          "`webhook`/analytics are structurally ineligible (ADR-047 §5.1)."
      end

    excluded
  end

  # --- tool discovery (runtime) ----------------------------------------------------------

  defp tool_modules do
    Samen.Automation.Action.tool_kinds()
    |> Enum.map(&Samen.Automation.Action.module_for/1)
    |> Enum.reject(&is_nil/1)
  end

  # --- bounded-term / AST helpers --------------------------------------------------------

  defp bounded_term?(term) when is_binary(term) or is_atom(term) or is_number(term)
       when is_boolean(term),
       do: true

  defp bounded_term?(term) when is_list(term), do: Enum.all?(term, &bounded_term?/1)

  defp bounded_term?(term) when is_map(term) and not is_struct(term),
    do: Enum.all?(term, fn {k, v} -> bounded_term?(k) and bounded_term?(v) end)

  defp bounded_term?(_), do: false

  defp vt_in_term?(term) when is_binary(term), do: String.contains?(term, @vt_sentinel)
  defp vt_in_term?(term) when is_atom(term) and not is_nil(term),
    do: String.contains?(Atom.to_string(term), @vt_sentinel)

  defp vt_in_term?(term) when is_list(term), do: Enum.any?(term, &vt_in_term?/1)

  defp vt_in_term?(term) when is_map(term) and not is_struct(term),
    do: Enum.any?(term, fn {k, v} -> vt_in_term?(k) or vt_in_term?(v) end)

  defp vt_in_term?(_), do: false

  defp source_path(mod) do
    case mod.module_info(:compile)[:source] do
      src when is_list(src) -> List.to_string(src)
      src when is_binary(src) -> src
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The body AST of `mod`'s `def tool_schema` clause (arity 0), or nil — scoped to `mod`'s
  # own `defmodule` block so a file carrying several tool modules resolves each correctly.
  defp tool_schema_body(ast, mod) do
    with block when not is_nil(block) <- module_block(ast, mod) do
      {_ast, body} =
        Macro.prewalk(block, nil, fn
          {:def, _, [{:tool_schema, _, args}, kw]} = node, nil when is_nil(args) or args == [] ->
            {node, Keyword.get(kw, :do)}

          node, acc ->
            {node, acc}
        end)

      body
    else
      _ -> nil
    end
  end

  # The `do` block of `defmodule <mod> do … end`, or nil.
  defp module_block(ast, mod) do
    {_ast, block} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, parts}, [do: block]]} = node, nil ->
          if safe(fn -> Module.concat(parts) end, nil) == mod, do: {node, block}, else: {node, nil}

        node, acc ->
          {node, acc}
      end)

    block
  end

  # Does the AST contain a call into Ash / a *.Repo / Application.get_env|fetch_env?
  defp dynamic_call?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn node, acc -> {node, acc or dynamic_call_node?(node)} end)

    found
  end

  defp dynamic_call_node?({{:., _, [alias_ast, fun]}, _, _args}) do
    alias_dangerous?(alias_ast) or
      (application_alias?(alias_ast) and fun in [:get_env, :fetch_env, :fetch_env!])
  end

  defp dynamic_call_node?(_), do: false

  defp alias_dangerous?({:__aliases__, _, parts}) when is_list(parts) do
    :Repo in parts or List.first(parts) == :Ash
  end

  defp alias_dangerous?(_), do: false

  defp application_alias?({:__aliases__, _, parts}), do: List.last(parts) == :Application
  defp application_alias?(_), do: false

  # --- (b) no vault-routed field is embeddable -------------------------------------------

  @doc "The (b) cross-check over a resource list (public for the unit test)."
  @spec embeddable_vault_violations([module()]) :: [String.t()]
  def embeddable_vault_violations(resources) do
    for resource <- resources,
        field <- embeddable_fields(resource),
        vault_routed?(resource, field) do
      "#{inspect(resource)}: embeddable field #{inspect(field)} is vault-routed (🔒) — " <>
        "a vault-routed value must never enter vector space (grants never unlock embedding; " <>
        "ADR-043 §7.2). Drop the field from the embeddable set or de-vault it."
    end
  end

  # The T67 embeddable-field seam: a resource opts in by exporting `embeddable_fields/0`.
  # Absent (today) ⇒ no embeddable fields ⇒ nothing to cross-check (green-and-real).
  defp embeddable_fields(resource) do
    if exports?(resource, :embeddable_fields, 0) do
      List.wrap(resource.embeddable_fields())
    else
      []
    end
  end

  defp vault_routed?(resource, field) do
    routed = safe(fn -> Samen.Pii.Info.vault_routed_columns(resource) end, [])
    pii = safe(fn -> Enum.map(Samen.Pii.Info.pii_attributes(resource), & &1.name) end, [])
    field in routed or field in pii
  end

  # --- (c) no Prompt template body carries a vt_ token -----------------------------------

  @doc "The (c) scan over a resource list (public for the unit test)."
  @spec prompt_body_vt_violations([module()]) :: [String.t()]
  def prompt_body_vt_violations(resources) do
    for resource <- resources,
        {name, body} <- prompt_template_bodies(resource),
        is_binary(body),
        String.contains?(body, @vt_sentinel) do
      "#{inspect(resource)}: Prompt template #{inspect(name)} body contains a `vt_` vault-token " <>
        "sentinel — a committed template must never embed a raw vault FK token (ADR-043 §7.5)."
    end
  end

  # The T68 Prompt-resource seam: a Prompt resource exports
  # `samen_ai_prompt_template_bodies/0 :: [{name, body_string}]`. Absent (today) ⇒ [].
  defp prompt_template_bodies(resource) do
    if exports?(resource, :samen_ai_prompt_template_bodies, 0) do
      List.wrap(resource.samen_ai_prompt_template_bodies())
    else
      []
    end
  end

  # --- helpers ---------------------------------------------------------------------------

  # `function_exported?/3` returns false for a not-yet-loaded module; ensure it is loaded first
  # so the seam detection is race-free (async tests / cold verifier runs).
  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp domains(opts) do
    case Keyword.get_values(opts, :domain) do
      [] ->
        otp_app = Mix.Project.config()[:app]
        Application.get_env(otp_app, :ash_domains, [])

      names ->
        Enum.map(names, &Module.concat([&1]))
    end
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
