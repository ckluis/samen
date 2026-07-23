defmodule Samen.Delivery.Smtp do
  @moduledoc """
  SMTP delivery adapter — **skeleton** (ADR-014 §2; operator TODO). Migrated to
  `Samen.Delivery.Provider` (ADR-038 §4.2 — the ADR-014 `Samen.Delivery.Adapter`
  contract, finalized and renamed); semantics are unchanged.

  `configured?/1` returns `true` only when the SMTP creds (`:host` + `:username` +
  `:password`) are present in the adapter config; otherwise `false`. `deliver/2`
  performs the real SMTP dispatch — but the live provider hookup is an operator
  TODO, so absent creds it returns `{:error, :not_configured}`, NEVER a faked
  `{:ok, _}`. This is the fail-honest seam: an unconfigured SMTP adapter blocks the
  send (via the SendWorker) rather than lying. SMTP has no webhooks/inbound and
  says so honestly (`use Samen.Delivery.Provider`'s `capabilities/0` default: `[]`).

  Web-dep-free: this module references no HTTP/web library. A host wiring a real
  SMTP client (e.g. `:gen_smtp`) pulls that dependency in the host app.
  """
  use Samen.Delivery.Provider

  alias Samen.Delivery.Message

  @impl true
  def configured?(config) when is_map(config) do
    present?(config, :host) and present?(config, :username) and present?(config, :password)
  end

  def configured?(_), do: false

  @impl true
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
