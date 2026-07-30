defmodule Samen.Automation.RunFinalize do
  @moduledoc """
  The body of `Automation.Run`'s `:finalize` update action (ADR-039 §8.1; T42).
  The target state (`:succeeded | :failed | :skipped`) is data-dependent (chosen
  by the caller via the `:to` argument), so — exactly like
  `Samen.Automation.EscalationAdvance`'s `:advance_step` — this uses the RUNTIME
  `AshStateMachine.transition_state/2` function rather than the compile-time
  `transition_state/1` DSL builtin (which only ever names ONE literal target).

  Stamps `finished_at` + `duration_ms` (computed from the row's own `started_at`,
  falling back to "now" if the run never reached `:running` — a skip decided
  before any action fired). An illegal transition (e.g. finalizing an
  already-terminal row twice) is refused by the state machine
  (`NoMatchingTransition`) rather than silently double-writing — callers
  (`Samen.Automation.RunRecord`) treat that as a benign idempotent no-op, never
  a crash (ADR-039 §5.1's "never crashes the engine" posture extended to the
  observability layer itself).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    target = Ash.Changeset.get_argument(changeset, :to)
    now = DateTime.utc_now()
    started_at = Ash.Changeset.get_data(changeset, :started_at) || now

    changeset
    |> Ash.Changeset.force_change_attribute(:finished_at, now)
    |> Ash.Changeset.force_change_attribute(
      :duration_ms,
      DateTime.diff(now, started_at, :millisecond)
    )
    |> AshStateMachine.transition_state(target)
  end
end
