defmodule Driftwood.Support.TriageAgent do
  @moduledoc """
  The ADR-047 §9#7 v1 vertical slice — driftwood's SUPPORT-TRIAGE agent, and the whole of
  the vertical's authored agent code.

  ADR-047 §1's driving example is *"why is shipment 4471 late **and who should own it?**"*
  A run answers it by planning over multiple turns, reading the org's own records through
  two governed READ tools, and — for the "who should own it" half — **proposing** a write
  that a person must approve before anything changes.

  ## Everything below the definition is inherited (the leverage guard)

  This module declares a name, a goal prompt, and three tool kinds. It contains no loop,
  no provider call, no masking code, no approval code, no persistence, no UI:

    * the multi-turn loop, budgets, durable cursor, cancel and breakers — `Samen.AI.Agent`;
    * the tool surface — the FOUR-WAY intersection (`Samen.AI.Agent.Tools`): the governed
      `Samen.Automation.Action` registry ∩ per-action `tool_schema/0` opt-in ∩ *this*
      list ∩ the run actor's real policy envelope. Declaring a kind here can only ever
      NARROW what is already governed — it can never widen it;
    * `assign_record_owner` carries `effect: :write`, so it **never executes when the
      agent calls it** (ADR-043 §6.2, ratified unamended at §9#1). The turn opens an E3
      approval and the run parks `:awaiting_approval` until a DISTINCT human approves —
      and it then executes with the APPROVER's authority, never the agent's;
    * masking is load-bearing and free: a `fetch_record` over `Driftwood.Support.Agent`
      (🔒 `full_name`, 🔒 `email`) reaches the model as `••••`, and the run's transcript is
      vault-routed with the ratified 90-day `:shred` retention;
    * the tenant run list / detail / decision card and the operator agent-health page are
      inherited by `samen_ai_routes` and `samen_operator_routes` in `DriftwoodWeb.Router`.

  ## Budgets are the ratified §9#3 defaults

  No `budgets:` key: `max_turns 8` / `max_tool_calls 12` / `max_input_tokens 60_000` /
  `max_output_tokens 8_000` / `deadline_seconds 600`. The **fail-honest floor** — an
  exhausted run is terminal `:budget_exhausted` and its last assistant line is NEVER
  promoted to an answer — is not configurable and is not a host decision.

  ## Keyless by default

  Driftwood configures no model provider, so a run here is honest about that: keyless
  hosts run under `Samen.AI.Provider.Scripted` (deterministic, `simulated?/0 == true`,
  SIMULATED badge on every turn row) and an unconfigured live provider fails honestly
  with `Samen.AI.configuration_hint/0` — never a fabricated answer.
  """

  use Samen.AI.Agent,
    name: "driftwood.support_triage",
    goal_prompt: """
    You are triaging one Driftwood support request about a freight load. Work the goal step
    by step: find the relevant records with search_records, read them with fetch_record, and
    — if the request needs an owner — propose one with assign_record_owner. Personal fields
    read back masked (••••); never guess a masked value and never ask for one.
    assign_record_owner does NOT take effect when you call it: it opens an approval that a
    person must approve. Reply FINAL: <answer> when done.
    """,
    tools: ["search_records", "fetch_record", "assign_record_owner"]
end
