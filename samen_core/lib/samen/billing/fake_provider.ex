defmodule Samen.Billing.FakeProvider do
  @moduledoc """
  The core, call-recording billing test double (ADR-038 §7.2/§3.6; T18/B1).

  Replaces the deleted `Samen.Scopes.Billing.SyncAdapter.Stub`. Like the old
  `Stub`, it records every call in a process-local accumulator so tests can assert
  the fake was invoked without any live vendor credentials. UNLIKE the old `Stub`,
  it is honest: `configured?/1` is driven by the `config` map (default `false`),
  and every callback (other than `configured?/1` and `redact_payload/1`) refuses
  with `{:error, :not_configured}` when the fake is not configured — it never
  returns a fake `{:ok, _}` for work it did not do.

  ## Configuring the fake

      FakeProvider.reset()
      FakeProvider.configured?(%{})                    # => false (default: honest refuse)
      FakeProvider.configured?(%{configured: true})     # => true

  A "configured" fake genuinely records + returns deterministic fake data (tagged
  `fake: true`, mirroring `Samen.Delivery.LocalSink`'s `sink: true` honesty tag) —
  it never claims a real vendor round-trip happened.

  ## Anti-tautology

  `FakeProvider.calls/0` returns the raw `{callback, args}` list, so tests can
  assert BOTH that the unconfigured path refuses (`:not_configured`, no call
  recorded as "successful") AND that the configured path genuinely records +
  returns real (fake-tagged) data — the pairing the codebase's red-path
  discipline (`Samen.RedPath`) requires elsewhere.
  """

  @behaviour Samen.Billing.Provider

  alias Samen.Billing.ProviderEvent

  @impl true
  def configured?(config) when is_map(config), do: Map.get(config, :configured) == true
  def configured?(_), do: false

  @impl true
  def create_checkout_session(attrs, config) do
    guarded(:create_checkout_session, attrs, config, fn ->
      {:ok,
       %{
         provider_session_id: "fake_cs_#{unique_ref()}",
         url: "https://fake.example.test/checkout/#{unique_ref()}",
         fake: true
       }}
    end)
  end

  @impl true
  def create_portal_session(attrs, config) do
    guarded(:create_portal_session, attrs, config, fn ->
      {:ok, %{url: "https://fake.example.test/portal/#{unique_ref()}", fake: true}}
    end)
  end

  @impl true
  def cancel_subscription(provider_subscription_id, opts, config) do
    guarded(
      :cancel_subscription,
      %{provider_subscription_id: provider_subscription_id, opts: opts},
      config,
      fn -> {:ok, %{provider_subscription_id: provider_subscription_id, status: :cancelled, fake: true}} end
    )
  end

  @impl true
  def change_subscription(provider_subscription_id, changes, config) do
    guarded(
      :change_subscription,
      %{provider_subscription_id: provider_subscription_id, changes: changes},
      config,
      fn -> {:ok, Map.merge(%{provider_subscription_id: provider_subscription_id, fake: true}, changes)} end
    )
  end

  @impl true
  def fetch_object(kind, provider_id, config) do
    guarded(:fetch_object, %{kind: kind, provider_id: provider_id}, config, fn ->
      {:ok, %{kind: kind, provider_id: provider_id, fake: true}}
    end)
  end

  @impl true
  def report_usage(batch, config) do
    guarded(:report_usage, %{batch: batch}, config, fn ->
      case Process.get(:billing_fake_provider_report_usage_result) do
        nil -> {:ok, %{reported: length(batch)}}
        overridden -> overridden
      end
    end)
  end

  @doc """
  Override the result a CONFIGURED `report_usage/2` returns (T25/B8 test control —
  simulates a transient provider failure so callers can prove their "no data loss
  on provider error" contract without a real vendor). `nil` (the default, restored
  by `reset/0`) means "honest success" (`{:ok, %{reported: length(batch)}}`).
  Process-local, like every other piece of `FakeProvider` state.
  """
  @spec configure_report_usage_result(term()) :: :ok
  def configure_report_usage_result(result) do
    Process.put(:billing_fake_provider_report_usage_result, result)
    :ok
  end

  @impl true
  def verify_and_parse_event(raw_body, headers, config) do
    guarded(:verify_and_parse_event, %{raw_body: raw_body, headers: headers}, config, fn ->
      {:ok,
       %ProviderEvent{
         provider: :fake,
         event_id: "fake_evt_#{unique_ref()}",
         kind: :unhandled,
         occurred_at: DateTime.utc_now(),
         provider_refs: %{},
         payload: redact_payload(%{})
       }}
    end)
  end

  @impl true
  def redact_payload(payload) when is_map(payload) do
    record_call(:redact_payload, %{payload: payload})
    Map.drop(payload, [:email, "email", :name, "name", :address, "address", :phone, "phone"])
  end

  @doc "Returns all recorded calls (`{callback, args}` tuples) for the current process."
  def calls, do: Process.get(:billing_fake_provider_calls, [])

  @doc "Clears the recorded calls (and any `report_usage/2` override) for the current process."
  def reset do
    Process.put(:billing_fake_provider_calls, [])
    Process.put(:billing_fake_provider_report_usage_result, nil)
  end

  # ---------------------------------------------------------------------------
  # Private helpers

  # The fail-honest gate shared by every callback except configured?/1 and
  # redact_payload/1: unconfigured -> {:error, :not_configured}, NEVER a fake
  # {:ok, _}. Only a configured fake records the call and runs `ok_fun`.
  defp guarded(callback, args, config, ok_fun) do
    if configured?(config) do
      record_call(callback, args)
      ok_fun.()
    else
      {:error, :not_configured}
    end
  end

  defp record_call(callback, args) do
    current = Process.get(:billing_fake_provider_calls, [])
    Process.put(:billing_fake_provider_calls, [{callback, args} | current])
  end

  defp unique_ref, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
