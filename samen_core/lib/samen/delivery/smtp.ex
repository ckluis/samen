defmodule Samen.Delivery.Smtp do
  @moduledoc """
  SMTP delivery adapter — **skeleton** (ADR-014 §2; operator TODO).

  `configured?/1` returns `true` only when the SMTP creds (`:host` + `:username` +
  `:password`) are present in the adapter config; otherwise `false`. `deliver/2`
  performs the real SMTP dispatch — but the live provider hookup is an operator
  TODO, so absent creds it returns `{:error, :not_configured}`, NEVER a faked
  `{:ok, _}`. This is the fail-honest seam: an unconfigured SMTP adapter blocks the
  send (via the SendWorker) rather than lying.

  Web-dep-free: this module references no HTTP/web library. A host wiring a real
  SMTP client (e.g. `:gen_smtp`) pulls that dependency in the host app.
  """
  @behaviour Samen.Delivery.Adapter

  alias Samen.Delivery.Message

  @impl Samen.Delivery.Adapter
  def configured?(config) when is_map(config) do
    present?(config, :host) and present?(config, :username) and present?(config, :password)
  end

  def configured?(_), do: false

  @impl Samen.Delivery.Adapter
  def deliver(%Message{} = _message, config) do
    if configured?(config) do
      # Operator TODO: dispatch via a real SMTP client using config creds and the
      # vault-revealed recipient email. Until wired, treat as not-yet-implemented
      # rather than a fake success.
      {:error, :not_implemented}
    else
      {:error, :not_configured}
    end
  end

  defp present?(config, key) do
    case Map.get(config, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end
end
