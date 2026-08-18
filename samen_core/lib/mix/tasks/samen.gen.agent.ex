defmodule Mix.Tasks.Samen.Gen.Agent do
  @shortdoc "Scaffold a first-party Samen.AI.Agent definition + its AgentCase proof into a vertical."

  @moduledoc """
  `mix samen.gen.agent` — the framework-first agent scaffolder (ADR-047 §10 → A7). A new
  vertical adopts a first-party durable multi-step agent at ≈0 authored LOC: this generator
  emits the `use Samen.AI.Agent` definition and its `Samen.AgentCase` proof, and the vertical
  mounts the surfaces with the ONE `samen_ai_routes` router call it already makes.

  SCHEMA: NONE — an agent definition owns no DB resource, reserves no abbrev, writes no
  migration (the durable `Samen.AI.Agent.Run`/`Turn`/`Kill` substrate is framework, shipped
  once). The abbrev registry is therefore HANDS-OFF by construction.

  ## Usage

      mix samen.gen.agent --scope Support --name Triage \\
        --tools search_records,fetch_record [--goal "..."] [--app-dir /path]

  Options:

    * `--scope` (required) — the vertical namespace (`<App>.<Scope>.<Name>Agent`).
    * `--name`  (required) — the agent's base name (module suffix + `<Name>Agent`).
    * `--tools` (optional) — a comma list of OPTED-IN registry tool kinds; each is validated
      against `Samen.Automation.Action.tool_kinds/0` (a bogus tool is a generate-time error —
      correct-by-construction). Defaults to none (`[]`).
    * `--goal`  (optional) — the compile-time-validated `goal_prompt` heredoc. Defaults to a
      generic step-by-step FINAL: prompt.
    * `--app-dir` (optional) — the app root. Defaults to the current directory.
  """

  use Mix.Task

  alias Samen.Gen.Agent

  @switches [scope: :string, name: :string, goal: :string, tools: :string, app_dir: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    spec = Agent.build_spec(opts)
    Agent.validate!(spec)
    [agent_path, test_path] = Agent.write!(spec)

    Mix.shell().info(
      "samen.gen.agent: wrote #{spec.agent_module} (#{Path.relative_to_cwd(agent_path)}) and its " <>
        "AgentCase proof (#{Path.relative_to_cwd(test_path)}). Mount it with your vertical's " <>
        "existing `samen_ai_routes(...)` call; run `mix test` to gate the scaffold green."
    )

    :ok
  end
end
