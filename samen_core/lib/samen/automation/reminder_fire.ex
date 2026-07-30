defmodule Samen.Automation.ReminderFire do
  @moduledoc """
  The body of the `:fire` update action driven by the Reminder's AshOban
  `:reminder_due` trigger (ADR-039 §6.3). Per due reminder it:

    1. **Idempotent state-guard** — `Ash.Changeset.filter/2` (the same mechanism
       `optimistic_lock/1` uses) adds `WHERE state = 'scheduled'` to the actual
       UPDATE statement, the SlaBreachWorker `breached = false` discipline applied
       here. A concurrent duplicate (two overlapping fires of the same row) loses
       the race at the DB layer — the second attempt's filter mismatch surfaces as
       `Ash.Error.Changes.StaleRecord` and the notification below never runs twice.
    2. **Transitions `scheduled -> sent`**, stamping `sent_at`.
    3. **Emits through `Notifications.Engine.emit/1`** (`event_type:
       "reminder_due"`) — digest batching (C8) applies with zero new plumbing. The
       body is FRAMEWORK COPY + the object ref only (never the reminder's own
       `note`, which stays exclusively a tenant-plane-readable vault field —
       INV-1; the Notify/SlaBreach precedent: "automations render framework copy
       + object refs, never plaintext").
  """
  use Ash.Resource.Change

  require Ash.Query
  import Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    # The AshOban due-scan's streamed record is only guaranteed to carry its
    # primary key + whatever the trigger's `where` touched — org_id/recipient_id/
    # subject_ref are NOT reliably loaded on `changeset.data` (the exact issue
    # `Samen.Automation.ScheduleAdvance` documents: "org_id is a universal column
    # not selected by default on the scan read"). Reload the fields we actually
    # need up front, once, and use THAT snapshot for the emit below — never the
    # after_action `result` (whose select shape is equally unreliable).
    id = Ash.Changeset.get_data(changeset, :id)
    reminder = reload(changeset.resource, id)

    changeset
    |> Ash.Changeset.filter({:state, [eq: :scheduled]})
    |> Ash.Changeset.force_change_attribute(:state, :sent)
    |> Ash.Changeset.force_change_attribute(:sent_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> Ash.Changeset.after_action(fn _changeset, result ->
      emit(reminder)
      {:ok, result}
    end)
  end

  defp emit(nil), do: :ok

  defp emit(reminder) do
    Samen.Notifications.Engine.emit(
      %{
        org_id: reminder.org_id,
        recipient_id: reminder.recipient_id,
        event_type: "reminder_due",
        channel: :in_app,
        rendered_body: "You have a reminder due for #{reminder.subject_ref}.",
        subject_ref: reminder.subject_ref,
        metadata: %{"reminder_id" => to_string(reminder.id)}
      },
      notify_opts()
    )
  end

  defp reload(_resource, nil), do: nil

  defp reload(resource, id) do
    resource
    |> filter(id == ^id)
    |> Ash.Query.ensure_selected([:id, :org_id, :recipient_id, :subject_ref])
    |> Ash.read!(authorize?: false)
    |> case do
      [record | _] -> record
      [] -> nil
    end
  rescue
    _ -> nil
  end

  defp notify_opts do
    :samen_core
    |> Application.get_env(Samen.Notifications.Engine, [])
    |> Keyword.take([:notification_module, :preference_module, :repo, :broadcaster])
  end
end
