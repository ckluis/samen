defmodule Samen.Mailbox.Sync do
  @moduledoc """
  The **two-way CRM email sync** engine (spec §I1, ruling M8; T74) — the consumer of
  the `Samen.Mailbox.Provider` seam.

  Three operations, all fail-honest, all org-pinned from the CONNECTION row (never
  from a message header):

    * `connect/2` — per-user mailbox connect. The provider's handshake result is
      persisted as a `Mailbox.Connection` whose `address` is 🔒 vault-routed.
    * `sync/2` — pull one bounded page from the connected mailbox and thread each
      message onto the matching CRM Person/Company timeline. Both directions the
      mailbox holds are recorded, so mail the user sent from Gmail/Outlook DIRECTLY
      (never through this product) still lands on the timeline.
    * `send/3` — send AS the connected mailbox and RECORD the send on the same
      timeline. This is the other half of "two-way": an outbound message is a
      first-class timeline entry, not a fire-and-forget.

  ## Fail-honest (ADR-014/024/026)

  Every operation refuses with `{:error, :not_configured}` when
  `Samen.Mailbox.Config.configured?/1` is false, BEFORE any write — and passes the
  provider's own `{:error, :not_configured | :not_implemented}` through verbatim.
  A sync that did not run is never reported as `{:ok, %{synced: 0}}`: "nothing new"
  and "never connected" are different answers and the surfaces render them
  differently.

  ## PII

  `subject` and `body` are persisted vault-routed (`:pii_body`); the counterparty
  address is persisted vault-routed (`:pii_email`). Both are sanitized at rest
  through the shipped `Samen.Support.Inbound.Sanitize` (T111/T59 stored-XSS lineage)
  and byte-capped before the write. No plaintext address, subject, or body column
  exists on the resource (INV-1).
  """

  require Ash.Query

  alias Samen.Mailbox.{Account, Config, Match, Message}
  alias Samen.Support.Inbound.Sanitize

  @doc """
  Connect a user's mailbox. `params` is host-authoritative: it MUST carry
  `:user_id` and `:org_id` is taken from `config` (the tenant boundary), plus
  whatever handshake input the adapter needs. Returns the persisted Connection.
  """
  @spec connect(map(), Config.t()) :: {:ok, struct()} | {:error, term()}
  def connect(params, %Config{} = config) when is_map(params) do
    with :ok <- ensure_configured(config),
         {:ok, %Account{} = account} <- config.provider.connect(params, config.provider_config) do
      config.connection_resource
      |> Ash.Changeset.for_create(:create, %{
        org_id: config.org_id,
        user_id: Map.get(params, :user_id),
        provider: provider_label(config.provider),
        external_account_id: account.external_account_id,
        cursor: account.cursor,
        status: :connected,
        connected_at: now(),
        # 🔒 vault-routed (:pii_email) — no plaintext address column exists.
        address: account.address
      })
      |> Ash.create(authorize?: false)
    end
  end

  @doc """
  Disconnect a mailbox: release it at the provider, then mark the row
  `:disconnected`. The row is KEPT (its synced messages stay on the timeline);
  only the live connection goes away.
  """
  @spec disconnect(struct(), Config.t()) :: {:ok, struct()} | {:error, term()}
  def disconnect(connection, %Config{} = config) do
    with :ok <- ensure_configured(config),
         :ok <- config.provider.disconnect(connection.external_account_id, config.provider_config) do
      connection
      |> Ash.Changeset.for_update(:update, %{status: :disconnected})
      |> Ash.update(authorize?: false)
    end
  end

  @doc """
  Pull one bounded page from the connected mailbox and thread it onto the CRM.

  Returns `{:ok, %{synced: n, skipped: n, failed: n, cursor: cursor, messages: [record]}}`.
  `:skipped` counts messages already recorded (deduped on the provider's own
  `external_id`) — a re-sync is idempotent, so a mailbox that is fetched twice does
  not double-post a conversation onto a timeline. `:failed` counts messages whose
  WRITE failed (no duplication risk; counted honestly rather than folded into
  `:skipped`).

  **Fail-closed dedupe.** If the duplicate LOOKUP itself fails, the batch ABORTS with
  `{:error, {:dedupe_unavailable, reason}}` and the cursor is NOT advanced — the next
  sync re-reads the same page. "I could not check" is never treated as "not a
  duplicate": a missed sync round is recoverable, a duplicated customer-visible
  conversation on a CRM timeline is not.
  """
  @spec sync(struct(), Config.t()) :: {:ok, map()} | {:error, term()}
  def sync(connection, %Config{} = config) do
    with :ok <- ensure_configured(config),
         {:ok, %{messages: messages} = page} <-
           config.provider.fetch(
             connection.external_account_id,
             connection.cursor,
             config.provider_config
           ) do
      messages
      |> Enum.take(config.max_messages_per_sync)
      |> Enum.reduce_while({[], 0, 0}, fn message, {acc, skipped, failed} ->
        case record(message, connection, config) do
          {:ok, record} ->
            {:cont, {[record | acc], skipped, failed}}

          :duplicate ->
            {:cont, {acc, skipped + 1, failed}}

          # FAIL-CLOSED (T74 fix round, LOW-2): the dedupe LOOKUP itself failed, so we
          # cannot know whether this message is already on a customer's timeline.
          # ABORT the batch and leave the cursor where it was — a missed sync round is
          # recoverable; a duplicated customer-visible conversation is not.
          {:error, {:dedupe_unavailable, _} = reason} ->
            {:halt, {:error, reason}}

          # A WRITE failure is not a duplication risk: count it honestly and continue.
          {:error, _reason} ->
            {:cont, {acc, skipped, failed + 1}}
        end
      end)
      |> case do
        {:error, reason} ->
          {:error, reason}

        {recorded, skipped, failed} ->
          cursor = Map.get(page, :cursor)
          {:ok, _} = touch_connection(connection, cursor, config)

          {:ok,
           %{
             synced: length(recorded),
             skipped: skipped,
             failed: failed,
             cursor: cursor,
             messages: Enum.reverse(recorded)
           }}
      end
    end
  end

  @doc """
  Send `attrs` AS the connected mailbox and record the send on the CRM timeline.

  `attrs` accepts `:to` (address or list), `:subject`, `:body`. The provider's
  receipt supplies the `external_id` used to dedupe the copy a later `fetch/3`
  returns from the Sent folder. Returns the persisted (outbound) mail record.
  """
  @spec send(map(), struct(), Config.t()) :: {:ok, struct()} | {:error, term()}
  def send(attrs, connection, %Config{} = config) when is_map(attrs) do
    message = %Message{
      direction: :outbound,
      to_addresses: to_list(Map.get(attrs, :to)),
      subject: Map.get(attrs, :subject),
      body: Map.get(attrs, :body),
      occurred_at: now()
    }

    with :ok <- ensure_configured(config),
         {:ok, receipt} <-
           config.provider.send(message, connection.external_account_id, config.provider_config) do
      message = %Message{message | external_id: Map.get(receipt, :external_id)}

      case record(message, connection, config) do
        {:ok, record} -> {:ok, record}
        :duplicate -> {:error, :duplicate_message}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Recording one message

  defp record(%Message{} = message, connection, %Config{} = config) do
    case duplicate?(message, config) do
      {:ok, true} -> :duplicate
      {:ok, false} -> create_record(message, connection, config)
      {:error, reason} -> {:error, {:dedupe_unavailable, reason}}
    end
  end

  defp create_record(%Message{} = message, connection, %Config{} = config) do
    counterparty = Message.counterparty(message)
    person = Match.person_for_address(counterparty, config)
    company = Match.company_for(person, counterparty, config)
    {subject_key, subject_id} = anchor(person, company)

    config.message_resource
    |> Ash.Changeset.for_create(:create, %{
      org_id: config.org_id,
      connection_id: connection.id,
      direction: message.direction,
      external_id: message.external_id,
      thread_key: Match.thread_key(message),
      occurred_at: message.occurred_at || now(),
      subject_key: subject_key,
      subject_id: subject_id,
      company_id: company && company.id,
      # 🔒 vault-routed: subject/body → :pii_body, counterparty → :pii_email.
      subject: bounded(message.subject, config.max_subject_bytes),
      body: bounded(message.body, config.max_body_bytes),
      counterparty_address: Match.normalize(counterparty)
    })
    |> Ash.create(authorize?: false)
  end

  # The provider's own immutable id is the dedupe key (org-pinned). A message with
  # no external id cannot be deduped — it is recorded (never silently dropped).
  #
  # FAIL-CLOSED (T74 fix round, LOW-2): a lookup that RAISES returns `{:error, _}`,
  # never `{:ok, false}`. Treating "I could not check" as "not a duplicate" would
  # re-post a customer-visible conversation onto a CRM timeline on any transient DB
  # blip — the caller aborts the batch instead and retries the same cursor.
  defp duplicate?(%Message{external_id: nil}, _config), do: {:ok, false}

  defp duplicate?(%Message{external_id: external_id}, config) do
    hit? =
      config.message_resource
      |> Ash.Query.new()
      |> Ash.Query.filter(org_id == ^config.org_id and external_id == ^external_id)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)
      |> Enum.any?()

    {:ok, hit?}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Primary anchor precedence: person ▸ company (matching ADR-041 §5.1's CRM
  # precedence). `company_id` rides alongside so a person-anchored message ALSO
  # appears on that company's timeline (zero timeline loss).
  defp anchor(nil, nil), do: {nil, nil}
  defp anchor(nil, company), do: {"crm.company", company.id}
  defp anchor(person, _company), do: {"crm.person", person.id}

  defp touch_connection(connection, cursor, _config) do
    connection
    |> Ash.Changeset.for_update(:update, %{cursor: cursor, last_synced_at: now()})
    |> Ash.update(authorize?: false)
  rescue
    _ -> {:ok, connection}
  end

  defp ensure_configured(%Config{} = config) do
    if Config.configured?(config), do: :ok, else: {:error, :not_configured}
  end

  defp bounded(nil, _max), do: nil

  defp bounded(value, max) when is_binary(value) do
    value |> binary_part(0, min(byte_size(value), max)) |> Sanitize.plain_text()
  end

  defp bounded(value, max), do: value |> to_string() |> bounded(max)

  defp to_list(nil), do: []
  defp to_list(value) when is_binary(value), do: [value]
  defp to_list(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp to_list(_), do: []

  defp provider_label(module) when is_atom(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
