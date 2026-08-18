defmodule Samen.Automation.Actions.SendEmail do
  @moduledoc """
  ADR-039 §5.2 #2 — `send_email`: routes through the ADR-038 `Samen.Delivery.Chokepoint`
  (C1) — the SAME suppression-checked, fail-honest send path every other C2
  consumer (`Samen.Scopes.Marketing.SendWorker`, `Samen.Delivery.Lifecycle.EmailWorker`,
  `Samen.Delivery.AuthMailer`, `Samen.Notifications.EmailDispatchWorker`) uses,
  never a second send path (T40 c2).

  `to` is a RECIPIENT SELECTOR (`"owner"` | a literal user id) — freeform
  to-addresses are deliberately excluded this run (a to-address is PII input
  flowing into an unattended sender, ADR-039 §13 "rejected alternatives").
  `assigns` values are validated as eligible-only interpolation targets (the
  same `{{subject.<attr>}}` convention every other action uses) but the shipped
  `Samen.Delivery.Message`/`Chokepoint` transport carries opaque ids only — it
  has no template-variable slot yet, so `assigns` is a forward seam (like
  `add_tag`'s Ticket-today seam): validated now, wired to a real template
  renderer when one lands.

  The chokepoint resolves the actual recipient email from the vault at DELIVER
  time (never here) — this action never touches plaintext PII; it hands the
  chokepoint an opaque `to_subscriber_id` only.
  """

  @behaviour Samen.Automation.Action

  alias Samen.Automation.Actions.Support
  alias Samen.Automation.Context
  alias Samen.Delivery.{Chokepoint, Message}

  @compiled_env Mix.env()

  @impl true
  def kind, do: :send_email

  @impl true
  def validate(config, _resource_key) when is_map(config) do
    to = config["to"] || "owner"
    template_key = config["template_key"]
    assigns = config["assigns"] || %{}

    cond do
      not is_binary(to) or to == "" ->
        {:error, :invalid_to}

      not is_binary(template_key) or template_key == "" ->
        {:error, :invalid_template_key}

      not is_map(assigns) ->
        {:error, :invalid_assigns}

      true ->
        {:ok, %{"to" => to, "template_key" => template_key, "assigns" => assigns}}
    end
  end

  def validate(_config, _resource_key), do: {:error, :invalid_config}

  @impl true
  def run(config, %Context{} = ctx) do
    recipient_id = Support.resolve_recipient(config["to"] || "owner", ctx)

    if is_nil(recipient_id) do
      {:error, :no_recipient}
    else
      message = %Message{
        send_id: Ecto.UUID.generate(),
        org_id: ctx.org_id,
        to_subscriber_id: recipient_id,
        template_id: config["template_key"]
      }

      case Chokepoint.send(message, send_opts()) do
        {:ok, receipt} ->
          {:ok, %{kind: :send_email, status: :sent, provider_message_id: id(receipt)}}

        {:error, :suppressed} ->
          {:error, :suppressed}

        {:error, :adapter_unconfigured} ->
          {:error, :adapter_unconfigured}

        {:error, reason} ->
          {:error, error_kind(reason)}
      end
    end
  end

  @impl true
  def undo(_config, _meta, _ctx), do: :ok

  defp send_opts do
    [
      fallback_adapter: cfg(:adapter),
      fallback_config: cfg(:adapter_config) || %{},
      env: env()
    ]
  end

  defp env, do: Application.get_env(:samen_core, :delivery_env, @compiled_env)

  defp cfg(key) do
    Application.get_env(:samen_core, __MODULE__, [])
    |> Keyword.get(key)
  end

  defp id(%{provider_message_id: id}), do: id
  defp id(_), do: nil

  defp error_kind(reason) when is_atom(reason), do: reason
  defp error_kind(_), do: :send_failed
end
