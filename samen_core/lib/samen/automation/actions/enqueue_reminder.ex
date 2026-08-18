defmodule Samen.Automation.Actions.EnqueueReminder do
  @moduledoc """
  ADR-039 §5.2 #8 — `enqueue_reminder`: builds DIRECTLY on the T41 E4 primitive
  (`Samen.Automation.Remind.schedule/2`) — no stub phase, the same T41
  dependency rationale as `escalate`. `remind_at` is EITHER `offset_minutes`
  from now OR `at_attribute` (an eligible timestamp attribute read from
  `ctx.subject` — eligible-only by construction, never a raw re-fetch). `note`
  is FRAMEWORK COPY ONLY (ADR-039 §5.2 #8: "user-freeform notes are the E4 UI's
  business, not E2's") — automation never authors freeform reminder text, so no
  `{{subject.*}}` interpolation is performed on it. `undo/3` cancels the
  created reminder.
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Actions.Support
  alias Samen.Automation.Context

  @impl true
  def kind, do: :enqueue_reminder

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    recipient = config["recipient"] || "owner"
    offset_minutes = config["offset_minutes"]
    at_attribute = config["at_attribute"]

    cond do
      not is_binary(recipient) or recipient == "" ->
        {:error, :invalid_recipient}

      is_nil(offset_minutes) and is_nil(at_attribute) ->
        {:error, :missing_schedule}

      not is_nil(offset_minutes) and not is_integer(offset_minutes) ->
        {:error, :invalid_offset_minutes}

      not is_nil(at_attribute) and (not is_binary(at_attribute) or at_attribute == "") ->
        {:error, :invalid_at_attribute}

      true ->
        {:ok,
         %{
           "recipient" => recipient,
           "offset_minutes" => offset_minutes,
           "at_attribute" => at_attribute,
           "note" => config["note"]
         }}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    recipient_id = Support.resolve_recipient(config["recipient"] || "owner", ctx)
    remind_at = resolve_remind_at(config, ctx)

    cond do
      is_nil(recipient_id) ->
        {:error, :no_recipient}

      is_nil(remind_at) ->
        {:error, :invalid_schedule}

      true ->
        attrs = %{
          org_id: ctx.org_id,
          recipient_id: recipient_id,
          subject_ref: ctx.subject_ref,
          remind_at: remind_at,
          note: framework_note(config, ctx),
          source: :automation
        }

        case Samen.Automation.Remind.schedule(attrs) do
          {:ok, reminder} -> {:ok, %{kind: :enqueue_reminder, reminder_id: to_string(reminder.id)}}
          {:error, :no_automation_module} -> {:error, :reminder_unwired}
          {:error, reason} -> {:error, error_kind(reason)}
        end
    end
  end

  @impl true
  def undo(_config, %{reminder_id: reminder_id}, %Context{actor: actor})
      when is_binary(reminder_id) do
    case Samen.Automation.Remind.cancel(reminder_id, actor) do
      {:ok, _reminder} -> :ok
      _other -> :ok
    end
  end

  def undo(_config, _meta, _ctx), do: :ok

  defp resolve_remind_at(%{"offset_minutes" => m}, _ctx) when is_integer(m) do
    DateTime.utc_now() |> DateTime.add(m * 60, :second) |> DateTime.truncate(:second)
  end

  defp resolve_remind_at(%{"at_attribute" => attr}, ctx) when is_binary(attr) and attr != "" do
    case Map.get(ctx.subject || %{}, Support.safe_atom(attr)) do
      %DateTime{} = dt -> dt
      _other -> nil
    end
  end

  defp resolve_remind_at(_config, _ctx), do: nil

  # Framework copy only — never subject data (ADR-039 §5.2 #8).
  defp framework_note(%{"note" => note}, _ctx) when is_binary(note) and note != "", do: note
  defp framework_note(_config, ctx), do: "Automated reminder for #{ctx.subject_ref}."

  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(_), do: :reminder_failed
end
