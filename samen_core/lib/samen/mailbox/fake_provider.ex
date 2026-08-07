defmodule Samen.Mailbox.FakeProvider do
  @moduledoc """
  The core, call-recording **mailbox test double** (spec §I1, T74). Mirrors
  `Samen.Delivery.FakeProvider`'s honesty discipline exactly: unconfigured refuses
  every callback except `configured?/1`, `capabilities/0` and `redact_payload/1`;
  a configured fake genuinely records and returns fake-tagged data.

  This is the provider CI uses. It is what makes the two-way loop provable without
  a single vendor credential: a test seeds the fake mailbox, `Samen.Mailbox.Sync`
  pulls it, threads it onto the CRM, sends a reply back through the SAME fake, and
  the sent message lands in the fake's outbox — where the NEXT `fetch/3` returns it
  as an `:outbound` message, exactly as a real IMAP `Sent` folder would.

  ## Configuring the fake

      FakeProvider.reset()
      FakeProvider.configured?(%{})                  # => false (honest default refuse)
      FakeProvider.configured?(%{configured: true})  # => true
      FakeProvider.set_capabilities([:inbound_sync, :outbound_send])
      FakeProvider.deliver_to_inbox([%Samen.Mailbox.Message{...}])

  All state is process-local (the same idiom `Samen.Delivery.FakeProvider` uses),
  so `capabilities/0` can stay argument-free and match the real callback shape.
  """

  use Samen.Mailbox.Provider

  alias Samen.Mailbox.{Account, Message}

  @calls_key :mailbox_fake_provider_calls
  @caps_key :mailbox_fake_provider_capabilities
  @inbox_key :mailbox_fake_provider_inbox
  @sent_key :mailbox_fake_provider_sent
  @connected_key :mailbox_fake_provider_connected

  # ---------------------------------------------------------------------------
  # Provider callbacks

  @impl true
  def configured?(config) when is_map(config), do: Map.get(config, :configured) == true
  def configured?(_), do: false

  @impl true
  def capabilities, do: Process.get(@caps_key, [])

  @impl true
  def connect(params, config) when is_map(params) do
    guarded(:connect, %{params: redact_payload(params)}, config, fn ->
      address = Map.get(params, :address) || Map.get(params, "address")
      ref = "fake_mbx_#{unique_ref()}"
      Process.put(@connected_key, ref)

      {:ok, %Account{external_account_id: ref, address: address, cursor: "0", meta: %{fake: true}}}
    end)
  end

  @impl true
  def disconnect(account_ref, config) do
    guarded(:disconnect, %{account_ref: account_ref}, config, fn ->
      Process.delete(@connected_key)
      :ok
    end)
  end

  @impl true
  def fetch(account_ref, cursor, config) do
    if :inbound_sync in capabilities() do
      guarded(:fetch, %{account_ref: account_ref, cursor: cursor}, config, fn ->
        offset = parse_cursor(cursor)
        all = inbox()
        page = Enum.drop(all, offset)

        {:ok, %{messages: page, cursor: Integer.to_string(offset + length(page))}}
      end)
    else
      {:error, :not_implemented}
    end
  end

  @impl true
  def send(%Message{} = message, account_ref, config) do
    if :outbound_send in capabilities() do
      guarded(:send, %{account_ref: account_ref, subject: message.subject}, config, fn ->
        external_id = "fake_out_#{unique_ref()}"

        recorded = %Message{
          message
          | direction: :outbound,
            external_id: external_id,
            occurred_at: message.occurred_at || DateTime.utc_now()
        }

        Process.put(@sent_key, sent() ++ [recorded])
        # A real Sent folder is part of the SAME mailbox the next fetch reads — the
        # fake models that, so the two-way loop is provable end to end.
        Process.put(@inbox_key, inbox() ++ [recorded])

        {:ok, %{external_id: external_id, fake: true}}
      end)
    else
      {:error, :not_implemented}
    end
  end

  @impl true
  def parse_push(raw_body, headers, config) do
    if :push_notifications in capabilities() do
      guarded(:parse_push, %{raw_body: raw_body, headers: headers}, config, fn ->
        {:ok, []}
      end)
    else
      {:error, :not_implemented}
    end
  end

  @impl true
  def redact_payload(payload) when is_map(payload) do
    Map.drop(payload, [
      :password,
      "password",
      :access_token,
      "access_token",
      :refresh_token,
      "refresh_token",
      :body,
      "body"
    ])
  end

  # ---------------------------------------------------------------------------
  # Test-facing controls

  @doc "All recorded `{callback, args}` calls for the current process."
  def calls, do: Process.get(@calls_key, [])

  @doc "The messages the fake mailbox currently holds (inbound + recorded sends)."
  def inbox, do: Process.get(@inbox_key, [])

  @doc "Only the messages the fake actually SENT (the outbound leg's receipt log)."
  def sent, do: Process.get(@sent_key, [])

  @doc "Seed the fake mailbox with messages a later `fetch/3` will return."
  def deliver_to_inbox(messages) when is_list(messages) do
    Process.put(@inbox_key, inbox() ++ messages)
    :ok
  end

  @doc "Set the capability list `capabilities/0` reports for the current process."
  def set_capabilities(caps) when is_list(caps), do: Process.put(@caps_key, caps)

  @doc "Clear every piece of process-local fake state."
  def reset do
    Enum.each([@calls_key, @caps_key, @inbox_key, @sent_key, @connected_key], &Process.delete/1)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private

  defp guarded(callback, args, config, ok_fun) do
    if configured?(config) do
      record_call(callback, args)
      ok_fun.()
    else
      {:error, :not_configured}
    end
  end

  defp record_call(callback, args),
    do: Process.put(@calls_key, [{callback, args} | Process.get(@calls_key, [])])

  defp parse_cursor(nil), do: 0

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end

  defp parse_cursor(n) when is_integer(n) and n >= 0, do: n
  defp parse_cursor(_), do: 0

  defp unique_ref, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()
end
