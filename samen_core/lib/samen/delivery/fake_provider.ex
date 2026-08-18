defmodule Samen.Delivery.FakeProvider do
  @moduledoc """
  The core, call-recording delivery test double (ADR-038 §7.2; T27/C1). Mirrors
  `Samen.Billing.FakeProvider`'s honesty discipline: unconfigured refuses every
  callback except `configured?/1` and `redact_payload/1`; a configured fake
  genuinely records + returns fake-tagged data. Used by core/lifecycle/vertical
  tests (and the two-fake provider-selection test) that need a real, honest
  `Samen.Delivery.Provider` double without any vendor credentials.

  ## Configuring the fake

      FakeProvider.reset()
      FakeProvider.configured?(%{})                    # => false (default: honest refuse)
      FakeProvider.configured?(%{configured: true})     # => true
      FakeProvider.set_capabilities([:deliverability_webhooks, :inbound])

  `capabilities/0` takes no arguments (matching the real callback shape), so
  per-test capability control is process-local state — the SAME idiom
  `calls/0`/`reset/0` already use.
  """

  use Samen.Delivery.Provider

  alias Samen.Delivery.{InboundMessage, ProviderEvent}

  @impl true
  def configured?(config) when is_map(config), do: Map.get(config, :configured) == true
  def configured?(_), do: false

  @impl true
  def capabilities, do: Process.get(:delivery_fake_provider_capabilities, [])

  @impl true
  def deliver(message, config) do
    guarded(:deliver, %{message: message}, config, fn ->
      {:ok, %{provider_message_id: "fake_msg_#{unique_ref()}", fake: true}}
    end)
  end

  @impl true
  def verify_and_parse_event(raw_body, headers, config) do
    if :deliverability_webhooks in capabilities() do
      guarded(:verify_and_parse_event, %{raw_body: raw_body, headers: headers}, config, fn ->
        {:ok,
         %ProviderEvent{
           provider: :fake,
           event_id: "fake_evt_#{unique_ref()}",
           kind: :unhandled,
           provider_message_id: nil,
           occurred_at: DateTime.utc_now(),
           payload: redact_payload(%{})
         }}
      end)
    else
      {:error, :not_implemented}
    end
  end

  @impl true
  def parse_inbound(raw_body, headers, config) do
    if :inbound in capabilities() do
      guarded(:parse_inbound, %{raw_body: raw_body, headers: headers}, config, fn ->
        {:ok, %InboundMessage{provider: :fake, message_id: "fake_in_#{unique_ref()}"}}
      end)
    else
      {:error, :not_implemented}
    end
  end

  @impl true
  def redact_payload(payload) when is_map(payload) do
    record_call(:redact_payload, %{payload: payload})
    Map.drop(payload, [:email, "email", :name, "name", :address, "address", :phone, "phone"])
  end

  @doc "Returns all recorded calls (`{callback, args}` tuples) for the current process."
  def calls, do: Process.get(:delivery_fake_provider_calls, [])

  @doc "Clears recorded calls AND the configured capability list for the current process."
  def reset do
    Process.put(:delivery_fake_provider_calls, [])
    Process.delete(:delivery_fake_provider_capabilities)
    :ok
  end

  @doc "Set the capability list `capabilities/0` reports for the current process."
  def set_capabilities(caps) when is_list(caps) do
    Process.put(:delivery_fake_provider_capabilities, caps)
  end

  # ---------------------------------------------------------------------------
  # Private helpers

  defp guarded(callback, args, config, ok_fun) do
    if configured?(config) do
      record_call(callback, args)
      ok_fun.()
    else
      {:error, :not_configured}
    end
  end

  defp record_call(callback, args) do
    current = Process.get(:delivery_fake_provider_calls, [])
    Process.put(:delivery_fake_provider_calls, [{callback, args} | current])
  end

  defp unique_ref, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
