defmodule Mix.Tasks.Samen.Verify.ReplaySchema do
  @shortdoc "Build-time check: every replay frame field must be a bounded type (no free string)."

  @moduledoc """
  `mix samen.verify.replay_schema` — the replay twin of `mix samen.verify.sink_schema`
  (ADR-052 §2.2 rule 3).

  `Samen.Replay.FrameSchema` declares every field a persisted replay frame may carry — the
  envelope, each kind's payload, every tree marker node and the param-shape entry — with a
  bounded type. This check fails the build when:

    * a field is typed as anything outside `Samen.Replay.FrameSchema.bounded_types/0`
      (`:string`, `:binary`, `:map`, `:any`, … — a name-carrier);
    * an `:enum` declares no closed `allowed:` set, or uses the reserved `allowed: :open`
      sentinel outside `open_enum_fields/0`;
    * a `:keep_listed` field (the ONE text type) declares no bounded `max_length`.

  The persist path validates every encoded frame against the same declaration
  (`Samen.Replay.FrameSchema.validate/1`), so the schema this task checks is the schema the
  store enforces.

  Exits 0 when clean, 1 otherwise (via `Samen.Verifier`).
  """

  use Mix.Task

  @task_name "samen.verify.replay_schema"

  # Test seam (red-path exit-code proof): a seeded `:string` payload field is appended so the
  # subprocess test can prove the task exits 1 WITHOUT mutating the real schema source.
  @inject_env "SAMEN_REPLAY_SCHEMA_INJECT_STRING_FIELD"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    violations = Samen.Replay.FrameSchema.violations(fields())
    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  defp fields do
    base = Samen.Replay.FrameSchema.all_fields()

    case System.get_env(@inject_env) do
      nil -> base
      name -> base ++ [{"payload render", {String.to_atom(name), :string, []}}]
    end
  end
end
