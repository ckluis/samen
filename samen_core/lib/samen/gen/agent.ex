defmodule Samen.Gen.Agent do
  @moduledoc """
  `mix samen.gen.agent`'s engine (ADR-047 §10 → A7) — the framework-first agent scaffolder.
  Adopting a first-party `Samen.AI.Agent` in a vertical is a DEFINITION plus one
  `samen_ai_routes` router call (the A6 leverage guard); this generator emits that
  definition and its `Samen.AgentCase` proof so *a new vertical adopts an agent at ≈0
  authored LOC*, correct-by-construction.

  ## What it emits (SCHEMA: NONE — an agent definition owns no DB resource)

  An agent is a plain `use Samen.AI.Agent` module (name + goal_prompt + a `tools:` list
  over the ONE governed `Samen.Automation.Action` registry). It reserves NO abbrev and
  writes NO migration — the durable substrate (`Samen.AI.Agent.Run`/`Turn`/`Kill`) is
  framework, shipped once. So the abbrev registry is HANDS-OFF *by construction* here, and
  the `gen_agent_probe.exs` T107 restore is byte-exact trivially (nothing to restore).

    * the agent DEFINITION module (`use Samen.AI.Agent, name:, goal_prompt:, tools:`);
    * a `Samen.AgentCase` proof test — DB-free and runnable in any host: it asserts the
      definition shape and that every declared tool resolves through the four-way
      intersection's arms 1-3 (`Samen.AI.Agent.Tools.resolve_definition/1` —
      correct-by-construction), and `use`s `Samen.AgentCase` so the loop-proof kit is wired
      into the vertical's scaffolding (a full `run_scripted` loop lands once the host
      migrates the agent substrate).

  ## Correct-by-construction

  `validate!/1` refuses a declared tool that is not an OPTED-IN registry action — so a
  scaffolded agent can never declare a tool the four-way intersection would reject at run
  start (framework-first: the error is at generate time, not fire time).
  """

  alias Samen.Gen.App
  alias Samen.Gen.Post

  defmodule Spec do
    @moduledoc false
    @enforce_keys [:app_module, :otp_app, :app_dir, :scope, :name, :agent_module, :agent_name, :goal, :tools]
    defstruct [:app_module, :otp_app, :app_dir, :scope, :name, :agent_module, :agent_name, :goal, :tools]
  end

  @doc "Build the agent spec from the CLI opts (`:scope`, `:name`, `:goal`, `:tools`, `:app_dir`)."
  @spec build_spec(keyword()) :: Spec.t()
  def build_spec(opts) do
    app_dir = Keyword.get(opts, :app_dir) || File.cwd!()
    {app_module, otp_app} = Post.read_app_identity!(app_dir)

    scope = require!(opts, :scope)
    name = require!(opts, :name)
    tools = normalize_tools(Keyword.get(opts, :tools))

    %Spec{
      app_module: app_module,
      otp_app: otp_app,
      app_dir: app_dir,
      scope: scope,
      name: name,
      agent_module: "#{app_module}.#{scope}.#{name}Agent",
      agent_name: "#{Macro.underscore(app_module)}.#{Macro.underscore(scope)}_#{Macro.underscore(name)}",
      goal: Keyword.get(opts, :goal) || default_goal(name),
      tools: tools
    }
  end

  @doc """
  Refuse a spec whose declared tool is not an OPTED-IN registry action — the
  correct-by-construction gate (a scaffolded tool the four-way intersection would reject is
  a generate-time error, never a run-time surprise).
  """
  @spec validate!(Spec.t()) :: :ok
  def validate!(%Spec{tools: tools}) do
    opted_in = MapSet.new(Samen.Automation.Action.tool_kinds())

    case Enum.reject(tools, &MapSet.member?(opted_in, &1)) do
      [] ->
        :ok

      bogus ->
        Mix.raise(
          "mix samen.gen.agent: declared tool(s) #{inspect(bogus)} are not opted-in agent " <>
            "tools. Opted-in tools: #{inspect(MapSet.to_list(opted_in))}. A scaffolded agent " <>
            "may only declare tools the four-way intersection admits (ADR-047 §5.1)."
        )
    end
  end

  @doc "Write the agent definition + its AgentCase proof. Returns the ABSOLUTE paths written."
  @spec write!(Spec.t()) :: [String.t()]
  def write!(%Spec{} = s) do
    b = bindings(s)

    files = [
      {agent_rel_path(s), agent_module_template()},
      {test_rel_path(s), agent_test_template()}
    ]

    for {rel, template} <- files do
      dest = Path.join(s.app_dir, App.render(rel, b))
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, App.render(template, b))
      dest
    end
  end

  # --- paths / bindings ------------------------------------------------------------------

  defp agent_rel_path(s) do
    "lib/#{lib_dir(s)}/#{Macro.underscore(s.scope)}/#{Macro.underscore(s.name)}_agent.ex"
  end

  defp test_rel_path(s) do
    "test/#{lib_dir(s)}/#{Macro.underscore(s.scope)}/#{Macro.underscore(s.name)}_agent_test.exs"
  end

  # The app's lib/test top dir mirrors the APP MODULE (Driftwood → driftwood, SamenCore →
  # samen_core), not the otp_app atom — the two coincide for verticals.
  defp lib_dir(s), do: Macro.underscore(s.app_module)

  defp bindings(s) do
    [
      {"agent_module", s.agent_module},
      {"agent_name", s.agent_name},
      {"goal", s.goal},
      {"tools_list", render_tools(s.tools)},
      {"scope", s.scope},
      {"name", s.name},
      {"test_module", "#{s.agent_module}Test"}
    ]
  end

  defp render_tools([]), do: "[]"
  defp render_tools(tools), do: "[" <> Enum.map_join(tools, ", ", &inspect/1) <> "]"

  defp normalize_tools(nil), do: []

  defp normalize_tools(csv) when is_binary(csv) do
    csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

  defp normalize_tools(list) when is_list(list), do: list

  defp default_goal(name) do
    "You are the #{name} agent. Work the goal step by step using your tools, then reply " <>
      "FINAL: <answer> when done."
  end

  defp require!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Mix.raise("mix samen.gen.agent: missing required --#{key}")
      "" -> Mix.raise("mix samen.gen.agent: --#{key} may not be empty")
      v -> v
    end
  end

  # --- templates (raw text; App.render substitutes `<%= key %>`) --------------------------

  @doc "The emitted agent-definition module template."
  def agent_module_template do
    """
    defmodule <%= agent_module %> do
      @moduledoc \"\"\"
      <%= agent_module %> — a first-party `Samen.AI.Agent` definition (ADR-047), scaffolded by
      `mix samen.gen.agent`. The loop, the four-way tool intersection, EG2 scrubbing, the
      propose-then-approve write path, budgets, and every rendered surface are FRAMEWORK code
      this vertical did NOT author: adoption is this definition plus one `samen_ai_routes`
      router call (the ≈0-LOC leverage guard).
      \"\"\"
      use Samen.AI.Agent,
        name: "<%= agent_name %>",
        goal_prompt: \"\"\"
        <%= goal %>
        \"\"\",
        tools: <%= tools_list %>
    end
    """
  end

  @doc "The emitted `Samen.AgentCase` proof — DB-free, correct-by-construction."
  def agent_test_template do
    """
    defmodule <%= test_module %> do
      @moduledoc \"\"\"
      `Samen.AgentCase` proof for `<%= agent_module %>` (scaffolded by `mix samen.gen.agent`).

      DB-free and runnable in any host: it proves the scaffolded definition is well-formed
      and that every declared tool resolves through the four-way intersection's arms 1-3
      (registry ∩ opt-in ∩ declared) — correct-by-construction. A full `run_scripted` loop
      proof (budget-honesty red + its positive control) lands once this host migrates the
      agent substrate (`Samen.AI.Agent.Run`/`Turn`/`Kill`); the `Samen.AgentCase` kit is
      already `use`d below so that proof is a few lines away.
      \"\"\"
      use ExUnit.Case, async: true
      use Samen.AgentCase

      alias <%= agent_module %>, as: Agent

      test "the scaffolded definition is well-formed" do
        assert Agent.definition().name == "<%= agent_name %>"
        assert Agent.definition().tools == <%= tools_list %>
        assert is_binary(Agent.definition().goal_prompt)
      end

      test "every declared tool resolves through the four-way intersection (correct-by-construction)" do
        assert {:ok, resolved} = Samen.AI.Agent.Tools.resolve_definition(Agent.definition())
        assert Enum.map(resolved, & &1.kind) == <%= tools_list %>
      end

      test "AgentCase is wired: a scripted turn can be staged for this agent" do
        assert :ok = script([{:final, "ok"}])
      end
    end
    """
  end
end
