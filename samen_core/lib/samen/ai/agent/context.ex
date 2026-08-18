defmodule Samen.AI.Agent.Context do
  @moduledoc """
  The ONE builder of an agent-origin `%Samen.Automation.Context{}` (ADR-047 §5.1,
  batch A3). An agent tool call fires a governed `Samen.Automation.Action`, whose
  fire-time contract is the `%Context{}` — but an agent run is NOT a workflow, and
  stuffing a run id into `:workflow_id` would be a lie the Health surface then
  renders. So:

    * `:origin` carries the honest provenance — `{:agent, run_id}` (the additive
      T40-style optional field on `%Context{}`);
    * `:workflow_id` is `nil` — nil-able ONLY on this path, and THIS function is
      the only site that constructs an agent-origin context (workflow contexts are
      built by `Samen.Automation.RunWorker`, which always has a real workflow id);
    * `:actor` is the run's OWNER scope, re-resolved from the durable row at turn
      time (`Samen.AI.Agent`'s `owner_scope/1` — the `Automation.RunWorker`
      owner-resolution rule; INV-2: never a synthesized or elevated actor);
    * `:depth` / `:chain` reuse the shipped loop-provenance fields (the §5.1
      recursion guard's substrate — an agent tool may not start another agent run
      at `depth > 0` in v1; no agent-starting tool exists at A3).
  """

  alias Samen.AI.Agent.Run
  alias Samen.Automation.Context

  @doc "Build the fire-time context for one agent tool call (kernel-only)."
  @spec build(Ash.Resource.record(), Samen.Scope.t()) :: Context.t()
  def build(%Run{} = run, %Samen.Scope{} = scope) do
    %Context{
      org_id: run.org_id,
      workflow_id: nil,
      run_id: run.id,
      subject_ref: "samen:arn:#{run.id}",
      subject: nil,
      actor: scope,
      event: nil,
      origin: {:agent, run.id},
      depth: run.depth,
      chain: run.chain
    }
  end
end
