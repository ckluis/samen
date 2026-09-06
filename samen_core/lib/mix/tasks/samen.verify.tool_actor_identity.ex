defmodule Mix.Tasks.Samen.Verify.ToolActorIdentity do
  @shortdoc "Refuse any tool schema that declares an actor/org/tenant identity parameter."

  @moduledoc """
  `mix samen.verify.tool_actor_identity` — the T185 verifier tier (backlog OSS-SCAN,
  ADR-043 §6.2/§7, findings/009 pattern #2: ZAQ's trusted-execution-context identity
  rule, AGPL-3.0 patterns-only, native re-implementation).

  ## The rule (structural, foundry-wide)

  Tool identity is `ctx[:actor]`-only. Every governed tool call already runs through
  `Samen.Automation.Action` arm 4 as `ctx.actor` (`Samen.AI.Agent.Tools`, ADR-047 §5.1) or
  through the MCP token's resolved scope (`Samen.AI.Mcp`, ADR-043 §9) — the loop-owned
  actor is the ONLY identity that ever reaches a governed Ash call. That convention has
  existed informally (`ctx.actor`, `agent/tools.ex` ~:18) but nothing enforced it
  STRUCTURALLY: a tool author could declare an `actor_id` / `org_id` / `tenant_id` model
  parameter — untrusted model output — and a careless `run/2` could read it instead of
  `ctx.actor`, spoofing or widening scope (ADR-043 §6.2: "the chokepoint never elevates,
  substitutes, or synthesizes an actor"). This tier refuses the DECLARATION itself: no
  tool schema, on any surface, may name an actor/org/tenant identity parameter — the
  static, cheap half of the invariant that makes the dynamic half (arm 4's `ctx.actor`
  binding) trustworthy by construction rather than by discipline.

  ## Foundry-wide: the two shared tool-schema surfaces

  This is scanned across BOTH registries samen ships, not one module's list, matching
  T185's "not scoped inside T177's OAuth-grant work" instruction:

    * **`Samen.Automation.Action`** (ADR-047 §5.1) — every kind in `tool_kinds()`
      (core + host `extra:` — a generated app's own opted-in tools are included, so a
      host cannot slip an actor param past this gate either), inspecting each module's
      `tool_schema/0` `:params` list.
    * **`Samen.AI.Mcp`** (ADR-043 §9) — the four `tools/0` MCP tool defs, inspecting each
      `inputSchema`'s `"properties"` keys.

  A future third tool surface that does not register through one of these two carries no
  proof from this tier — the fix is to route it through the shared registry, not to grow
  a third scanner (the same "one registry stays the one allowlist" discipline `action.ex`
  documents for `tool_kinds/0`).

  ## What counts as an identity parameter

  A param/property name normalizes (camelCase→`_`, downcase, split on non-letters) to a
  token set containing `actor`, `org`, `organization`, `tenant`, `account`, `behalf`, or
  `as` — catches `actor`, `actor_id`, `org_id`, `organization_id`, `tenant_id`,
  `tenant_org_id`, `actorId` (JSON-Schema-style camelCase, the MCP surface's convention),
  and (UXD-03, widened — see below) `account_id`, `on_behalf_of`, `acting_as`, `as_user`,
  etc., while leaving unrelated business fields (`resource`, `id`, `query`, `limit`,
  `user_id`) untouched. `user_id` is deliberately NOT blocked: `assign_record_owner`'s
  `user_id` names a TARGET record to mutate, not the calling actor's own identity — the
  rule is about the actor's own identity leaking in as a parameter, not every UUID-shaped
  arg.

  **UXD-03 (`_orch/verify/T11-verdict.json`'s `strongest_attack`, backlog.yaml:195).** The
  original three-token set (`actor`/`org`/`organization`/`tenant`) matched only the
  literal words the backlog line names, so `on_behalf_of`, `account_id`, `acting_as`, and
  `as_user` — all identity-shaped params naming who the model is acting as/for — passed
  `identity_leak?/1` as `false`. Widened to `account`, `behalf`, `as`, which catches all
  four without touching `user_id` (verified: `["user","id"]` contains none of the three).
  **This remains a CLOSED vocabulary, not general identity-shape inference** — a still
  further rename (e.g. `impersonate`, `requester_ref`) would again pass undetected; that
  residual is the same class of limit the original three-token set always had, only
  narrower now, not eliminated. Route a genuinely new identity spelling here, not around
  the gate.

  **Known OVER-approximation, accepted (UXD-03, `_orch/verify/T11-verdict-attempt3.json`).**
  The bare token `as` also flags unrelated names that merely tokenize to it — `same_as`,
  `known_as`, `as_of`, `as_of_date`, `base_as` all return `true` from `identity_leak?/1`.
  This is deliberate and fail-CLOSED: a false positive blocks a build and is renamed or
  argued in review, whereas a false negative admits an identity-spoofing parameter. The
  deliberate sparing of TARGET-record fields is unaffected and pinned by test.

  ## Diagnostics

      FAIL: samen.verify.tool_actor_identity found 1 violation(s):
        • Samen.Automation.Actions.RogueTool ("rogue_tool"): tool_schema/0 declares an
          actor/org/tenant identity parameter "org_id" — tool identity MUST come from
          ctx[:actor] only (ADR-043 §6.2); an LLM-supplied identity parameter can
          spoof or widen scope.

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `:erlang.halt/1`).
  """

  use Mix.Task

  @task_name "samen.verify.tool_actor_identity"

  # The bounded identity-token blocklist (§ "What counts as an identity parameter").
  # UXD-03: widened with `account`/`behalf`/`as` to catch `on_behalf_of`, `account_id`,
  # `acting_as`, `as_user` (V11's strongest_attack, T11-verdict.json) — still a CLOSED
  # vocabulary, see the moduledoc note.
  @identity_tokens ~w(actor org organization tenant account behalf as)

  # Test seam (red-path exit-code proof, same discipline as
  # `samen.verify.sink_schema`'s `SAMEN_SINK_SCHEMA_INJECT_STRING_FIELD`): when set, a
  # synthetic param name is run through the REAL `identity_leak?/1` predicate the
  # subprocess red-path test proves the task exits 1 on a leaking name WITHOUT mutating
  # any shipped tool module or the runtime registry. Absent in every non-test invocation.
  @inject_env "SAMEN_TOOL_ACTOR_IDENTITY_INJECT_PARAM"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    Samen.Verifier.halt_if_violations(@task_name, violations())
  end

  @doc """
  Compute the violations (list of human-readable strings), without halting — the
  test-callable seam. Both surfaces this tier scans are RUNTIME registries
  (`Samen.Automation.Action.tool_kinds/0`, `Samen.AI.Mcp.tools/0`), not a file-tree walk,
  so unlike the tree-walking tiers this task takes no `--root`: a positive control
  registers a rogue module via `config :samen_core, Samen.Automation.Action, extra: %{...}`
  (in-process unit layer) or the `#{@inject_env}` env var (exit-code layer).
  """
  @spec violations() :: [String.t()]
  def violations do
    action_tool_violations() ++ mcp_tool_violations() ++ injected_violations()
  end

  defp injected_violations do
    case System.get_env(@inject_env) do
      nil ->
        []

      name ->
        if identity_leak?(name) do
          [
            "TEST-INJECTED tool (#{@inject_env}=#{inspect(name)}): tool_schema declares an " <>
              "actor/org/tenant identity parameter #{inspect(name)} — tool identity MUST " <>
              "come from ctx[:actor] only (ADR-043 §6.2)."
          ]
        else
          []
        end
    end
  end

  # --- Samen.Automation.Action registry (agent tools, ADR-047 §5.1) ----------------------

  @doc "Violations over the `Samen.Automation.Action` tool-schema params (public for tests)."
  @spec action_tool_violations() :: [String.t()]
  def action_tool_violations do
    for {kind, mod} <- action_tool_modules(),
        param_name <- action_param_names(mod),
        identity_leak?(param_name) do
      "#{inspect(mod)} (#{inspect(kind)}): tool_schema/0 declares an actor/org/tenant " <>
        "identity parameter #{inspect(param_name)} — tool identity MUST come from " <>
        "ctx[:actor] only (ADR-043 §6.2); an LLM-supplied identity parameter can spoof " <>
        "or widen scope."
    end
  end

  defp action_tool_modules do
    Samen.Automation.Action.tool_kinds()
    |> Enum.map(fn kind -> {kind, Samen.Automation.Action.module_for(kind)} end)
    |> Enum.reject(fn {_kind, mod} -> is_nil(mod) end)
  end

  defp action_param_names(mod) do
    schema = safe(fn -> mod.tool_schema() end, :not_a_tool)

    with true <- is_map(schema) and not is_struct(schema),
         params when is_list(params) <- Map.get(schema, :params) || Map.get(schema, "params") do
      Enum.map(params, fn param ->
        (is_map(param) && (Map.get(param, :name) || Map.get(param, "name"))) || nil
      end)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  # --- Samen.AI.Mcp tool catalogue (ADR-043 §9) -------------------------------------------

  @doc "Violations over the MCP `tools/0` inputSchema properties (public for tests)."
  @spec mcp_tool_violations() :: [String.t()]
  def mcp_tool_violations do
    for tool <- safe(fn -> Samen.AI.Mcp.tools() end, []),
        property_name <- mcp_property_names(tool),
        identity_leak?(property_name) do
      "MCP tool #{inspect(Map.get(tool, "name"))}: inputSchema declares an actor/org/tenant " <>
        "identity property #{inspect(property_name)} — tool identity MUST come from the " <>
        "resolved token scope (ctx[:actor]) only (ADR-043 §6.2/§9); an LLM-supplied " <>
        "identity property can spoof or widen scope."
    end
  end

  defp mcp_property_names(tool) when is_map(tool) do
    tool
    |> Map.get("inputSchema", %{})
    |> Map.get("properties", %{})
    |> Map.keys()
  end

  defp mcp_property_names(_), do: []

  # --- shared identity-leak predicate ------------------------------------------------------

  @doc "Does `name` normalize to a token set containing an identity token? (public for tests)"
  @spec identity_leak?(term()) :: boolean()
  def identity_leak?(name) when is_binary(name) or is_atom(name) do
    tokens =
      name
      |> to_string()
      # camelCase boundary ("actorId" / "orgId") -> a splittable separator, same as "_".
      |> String.replace(~r/(?<=[a-z0-9])(?=[A-Z])/, "_")
      |> String.downcase()
      |> String.split(~r/[^a-z]+/, trim: true)

    Enum.any?(tokens, &(&1 in @identity_tokens))
  end

  def identity_leak?(_), do: false

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
