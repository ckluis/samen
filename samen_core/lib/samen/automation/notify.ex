defmodule Samen.Automation.Notify do
  @moduledoc """
  The `notify` action (ADR-039 §5.2 #1) — the minimal end-to-end proof T39 ships so
  the engine can be exercised create→dispatch→run→effect. It routes through
  `Samen.Notifications.Engine.emit/1`, so it inherits the whole masking posture for
  free (INV-1): the engine is preference-gated, vault-routes the rendered body, and
  the request this action builds carries ONLY framework copy + an object ref — never
  a subject attribute value, never a `vt_*` token (ADR-039 §10.3, the SlaBreach
  notification precedent).

  ## Config (bounded)

      %{"recipient" => "owner" | "org" | "<user_id>",
        "event_type" => "workflow.fired",           # bounded label
        "template_key" => "workflow_notify"}         # framework copy key

  No config field ever carries a subject value: `template_key` selects framework copy,
  never interpolated PII. (Subject interpolation into notification bodies is a T40
  concern, and even there the interpolated attribute must be condition-eligible.)
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Context

  @impl true
  def kind, do: :notify

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    recipient = config["recipient"] || config[:recipient] || "owner"
    event_type = config["event_type"] || config[:event_type] || "workflow.fired"
    template_key = config["template_key"] || config[:template_key] || "workflow_notify"

    cond do
      not is_binary(recipient) or recipient == "" ->
        {:error, :invalid_recipient}

      not is_binary(event_type) or event_type == "" ->
        {:error, :invalid_event_type}

      true ->
        {:ok,
         %{
           "recipient" => recipient,
           "event_type" => event_type,
           "template_key" => to_string(template_key)
         }}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    recipient_id = resolve_recipient(config["recipient"] || config[:recipient] || "owner", ctx)

    if is_nil(recipient_id) do
      {:error, :no_recipient}
    else
      request = %{
        org_id: ctx.org_id,
        recipient_id: recipient_id,
        event_type: config["event_type"] || config[:event_type] || "workflow.fired",
        channel: :in_app,
        # Framework copy ONLY — the object ref travels, subject data never does.
        rendered_body: framework_copy(config, ctx),
        subject_ref: ctx.subject_ref,
        metadata: %{"workflow_id" => ctx.workflow_id}
      }

      case Samen.Notifications.Engine.emit(request, notify_opts()) do
        {:ok, :suppressed} -> {:ok, %{kind: :notify, status: :suppressed}}
        {:ok, notification} -> {:ok, %{kind: :notify, status: :sent, notification_id: id(notification)}}
        {:error, reason} -> {:error, error_kind(reason)}
      end
    end
  end

  # "owner" → the run's owner-actor id; "org" → the org id (org-level recipient, the
  # SlaBreach precedent); otherwise a literal user id. All bounded ids.
  defp resolve_recipient("owner", ctx), do: actor_id(ctx.actor)
  defp resolve_recipient("org", ctx), do: ctx.org_id
  defp resolve_recipient(user_id, _ctx) when is_binary(user_id), do: user_id
  defp resolve_recipient(_, ctx), do: actor_id(ctx.actor)

  defp actor_id(%{actor: %{id: id}}), do: id
  defp actor_id(%{id: id}), do: id
  defp actor_id(id) when is_binary(id), do: id
  defp actor_id(_), do: nil

  # Framework copy: names the workflow + subject ref, never a subject attribute value.
  defp framework_copy(_config, %Context{} = ctx) do
    "Automation #{ctx.workflow_id} fired for #{ctx.subject_ref}."
  end

  defp notify_opts do
    :samen_core
    |> Application.get_env(Samen.Notifications.Engine, [])
    |> Keyword.take([:notification_module, :preference_module, :repo, :broadcaster])
  end

  defp id(%{id: id}), do: id
  defp id(_), do: nil

  defp error_kind(:no_notification_module), do: :notify_unwired
  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(_), do: :notify_failed
end
