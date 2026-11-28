defmodule Samen.Automation.EscalationAdvance do
  @moduledoc """
  The body of the `:advance_step` update action driven by the Escalation's AshOban
  `:escalation_due` trigger (ADR-039 §7.2/§7.3). Per due escalation it:

    1. **Emits the current chain step's notification** (`event_type:
       "escalation_step"`) — framework copy + bounded ids/refs only, the
       SlaBreach-notification precedent (§7.2: "framework copy only... subject
       data never travels").
    2. **Advances `current_step`** and computes `next_action_at` from the NEXT
       step's `after_minutes` offset (relative to `deadline_at` — step 0 fires AT
       `deadline_at`; step n at `deadline_at + after_minutes`).
    3. **Transitions state** — `:escalating` when a further step remains,
       `:exhausted` when the chain is exhausted. The `:advance_step` transition
       declares BOTH legal targets (`to: [:escalating, :exhausted]`); this module
       picks the correct one at runtime via `AshStateMachine.transition_state/2`
       (the underlying runtime function the `transition_state/1` DSL builtin
       wraps at compile time — used here because the target is data-dependent).
       An illegal target (neither declared `to`) is refused by the machine
       (`NoMatchingTransition`) — a resolved/exhausted/cancelled escalation can
       never be re-advanced (§7.1: "never walks further steps").

  ## One advance per step (ADR-039 §7.3)

  The update is guarded in SQL on `current_step`: it applies only while the row is still at
  the step this advance was read at (`filter(current_step == ^step)`). Of two advances of the
  same step, one applies and the other matches no row and is refused as a stale record, so a
  step is notified once. The step is the one on the record the scan handed over; a record that
  arrives without it falls back to the reloaded snapshot.
  """
  use Ash.Resource.Change

  require Ash.Query
  import Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    # The AshOban due-scan's streamed record is only guaranteed to carry its
    # primary key + whatever the trigger's `where` touched — org_id/chain/
    # deadline_at etc. are NOT reliably loaded on `changeset.data` (the exact
    # issue `Samen.Automation.ScheduleAdvance` documents for Workflow's own
    # schedule scan). Reload the FULL snapshot up front, once, and use it both
    # for the transition decision AND the emit below.
    id = Ash.Changeset.get_data(changeset, :id)
    escalation = reload(changeset.resource, id)

    advance(changeset, escalation)
  end

  # The step the caller read: the record's own `current_step`, else the reloaded snapshot's.
  defp read_step(changeset, escalation) do
    case Ash.Changeset.get_data(changeset, :current_step) do
      step when is_integer(step) -> step
      _not_loaded -> escalation.current_step || 0
    end
  end

  defp advance(changeset, nil), do: changeset

  defp advance(changeset, escalation) do
    step_idx = read_step(changeset, escalation)
    changeset = Ash.Changeset.filter(changeset, Ash.Expr.expr(current_step == ^step_idx))
    chain = escalation.chain || []
    deadline_at = escalation.deadline_at

    case Enum.at(chain, step_idx) do
      nil ->
        # Defensive: no step at this index (an empty/short chain) — exhausted
        # immediately, never a crash.
        changeset
        |> AshStateMachine.transition_state(:exhausted)
        |> Ash.Changeset.force_change_attribute(:next_action_at, nil)

      step ->
        next_idx = step_idx + 1
        next_step = Enum.at(chain, next_idx)
        target = if next_step, do: :escalating, else: :exhausted

        changeset
        |> AshStateMachine.transition_state(target)
        |> Ash.Changeset.force_change_attribute(:current_step, next_idx)
        |> Ash.Changeset.force_change_attribute(:next_action_at, next_action_at(deadline_at, next_step))
        |> Ash.Changeset.after_action(fn _cs, result ->
          emit_step(escalation, step, step_idx)
          {:ok, result}
        end)
    end
  end

  defp reload(_resource, nil), do: nil

  defp reload(resource, id) do
    resource
    |> filter(id == ^id)
    |> Ash.Query.ensure_selected([
      :id,
      :org_id,
      :kind,
      :dedupe_key,
      :subject_ref,
      :deadline_at,
      :chain,
      :current_step,
      :next_action_at,
      :state
    ])
    |> Ash.read!(authorize?: false)
    |> case do
      [record | _] -> record
      [] -> nil
    end
  end

  defp next_action_at(_deadline_at, nil), do: nil

  defp next_action_at(deadline_at, %{"after_minutes" => minutes}) when is_number(minutes) do
    DateTime.add(deadline_at, trunc(minutes * 60), :second)
  end

  defp next_action_at(deadline_at, _step), do: deadline_at

  defp emit_step(escalation, step, step_idx) do
    recipient_id = resolve_recipient(Map.get(step, "recipient", "org"), escalation)
    channel = channel_of(Map.get(step, "channel", "in_app"))

    Samen.Notifications.Engine.emit(
      %{
        org_id: escalation.org_id,
        recipient_id: recipient_id,
        event_type: "escalation_step",
        channel: channel,
        rendered_body: "Escalation step #{step_idx} fired for #{escalation.subject_ref}.",
        subject_ref: escalation.subject_ref,
        metadata: %{"escalation_id" => to_string(escalation.id), "kind" => escalation.kind}
      },
      notify_opts()
    )
  end

  defp resolve_recipient("org", escalation), do: escalation.org_id
  defp resolve_recipient(user_id, _escalation) when is_binary(user_id), do: user_id
  defp resolve_recipient(_other, escalation), do: escalation.org_id

  defp channel_of("email"), do: :email
  defp channel_of(_other), do: :in_app

  defp notify_opts do
    :samen_core
    |> Application.get_env(Samen.Notifications.Engine, [])
    |> Keyword.take([:notification_module, :preference_module, :repo, :broadcaster])
  end
end
