defmodule Samen.Delivery.Api do
  @moduledoc """
  HTTP-API (ESP) delivery adapter — **skeleton** (ADR-014 §2; operator TODO).

  `configured?/1` returns `true` only when the ESP creds (`:api_key` + `:endpoint`)
  are present in the adapter config; otherwise `false`. `deliver/2` performs the
  real API dispatch — but the live provider hookup is an operator TODO, so absent
  creds it returns `{:error, :not_configured}`, NEVER a faked `{:ok, _}`. Same
  fail-honest seam as `Samen.Delivery.Smtp`.

  Web-dep-free: this module references no HTTP client at compile time. A host
  wiring a real ESP (SendGrid/Postmark/SES) pulls the HTTP client dependency in
  the host app and supplies it via config.
  """
  @behaviour Samen.Delivery.Adapter

  alias Samen.Delivery.Message

  @impl Samen.Delivery.Adapter
  def configured?(config) when is_map(config) do
    present?(config, :api_key) and present?(config, :endpoint)
  end

  def configured?(_), do: false

  @impl Samen.Delivery.Adapter
  def deliver(%Message{} = _message, config) do
    if configured?(config) do
      # Operator TODO: POST to the ESP endpoint with the api_key and the
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
