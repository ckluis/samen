defmodule Samen.Support.Inbound.Ingest do
  @moduledoc """
  The C5 inbound-email → support-ticket consumer (T59). Maps an adapter-normalized
  `Samen.Delivery.InboundMessage` into a NEW ticket or a threaded reply on an EXISTING
  ticket's conversation, applying every governance rule the untrusted-input contract
  demands. The capability is framework-first: this module + its siblings live in
  `samen_core`; a vertical adopts it by passing a `Samen.Support.Inbound.Config` built
  from its OWN Support/CRM resource modules (≈0 authored LOC — see the demo/vertical
  wiring test).

  ## Pipeline (each stage is hostile-input-safe)

    1. **Parse** (`Parse.normalize/2`) — bound/normalize every field; no crash on
       malformed/missing/oversized.
    2. **Loop-guard** (`LoopGuard.classify/2`) — an auto-submitted / bulk / system /
       own-identity message is SUPPRESSED: no ticket, no auto-reply (the loop-breaker).
       The disposition is RECORDED (`{:ok, %{disposition: :suppressed, reason: …}}`),
       never silently dropped.
    3. **Thread** (`Threading`) — resolve a referenced ticket ORG-SCOPED; a forged
       cross-org reference cannot attach (opens a new ticket in the correct org).
    4. **Runaway bound** — a thread already holding `max_inbound_per_thread` messages
       stops accepting inbound (`{:ok, %{disposition: :rate_capped}}`) — a mail-loop
       cannot grow a thread without limit.
    5. **Persist** — sender email/name → a vaulted contact (CRM `Person`); body →
       `Message.body` (🔒 vault); subject/body/display-name are SANITIZED at rest
       (stored-XSS defense, T111 lineage). `org_id` is pinned from trusted config.
    6. **Attachments** — each lands via `Samen.Files.upload/3` (the chokepoint) as
       `:quarantined`; storage keys go on `Message.attachments`.
    7. **Auto-reply** — only for genuine customer mail (loop-suppressed mail never
       reaches here); via the host-supplied `config.auto_reply` fun (nil = none).

  ## Return

    * `{:ok, %{disposition: :created | :threaded, ticket_id:, conversation_id:,
      message_id:, contact_id:, auto_reply: :sent | :none}}`
    * `{:ok, %{disposition: :suppressed, reason:}}` — loop signal (recorded, no writes)
    * `{:ok, %{disposition: :rate_capped, ticket_id:}}` — runaway bound hit
    * `{:error, reason}` — a real failure (never a fabricated success)

  ## `ingest_raw/5` — fail-honest adapter seam

  `ingest_raw/5` runs an adapter's `parse_inbound/3` and passes its result THROUGH: an
  unconfigured inbound adapter returns `{:error, :not_configured}` and this consumer
  surfaces exactly that — it NEVER fabricates a ticket from a non-parse (ADR-014).
  """

  require Ash.Query
  require Logger

  alias Samen.Delivery.InboundMessage
  alias Samen.Support.Inbound.{Config, LoopGuard, Parse, Sanitize, Threading}

  @doc """
  Ingest an already-parsed `InboundMessage`.
  """
  @spec ingest(InboundMessage.t(), Config.t()) :: {:ok, map()} | {:error, term()}
  def ingest(%InboundMessage{} = msg, %Config{} = config) do
    parsed = Parse.normalize(msg, config)

    case LoopGuard.classify(parsed, config) do
      {:suppress, reason} ->
        {:ok, %{disposition: :suppressed, reason: reason}}

      :deliver ->
        do_route(parsed, config)
    end
  rescue
    e ->
      # Untrusted input must never crash the ingest path — convert any unexpected
      # error into an honest {:error, _} (no fabricated success).
      Logger.error("inbound ingest failed: #{Exception.message(e)}")
      {:error, {:ingest_failed, Exception.message(e)}}
  end

  @doc """
  Parse a raw vendor payload through an adapter, then ingest. Fail-honest: an
  unconfigured / unimplemented inbound adapter's `{:error, :not_configured | :not_implemented}`
  is returned verbatim — never turned into a fake ticket.
  """
  @spec ingest_raw(module(), binary(), [{String.t(), String.t()}], map(), Config.t()) ::
          {:ok, map()} | {:error, term()}
  def ingest_raw(provider, raw_body, headers, provider_config, %Config{} = config) do
    case provider.parse_inbound(raw_body, headers, provider_config) do
      {:ok, %InboundMessage{} = msg} -> ingest(msg, config)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- routing ---------------------------------------------------------------

  defp do_route(parsed, config) do
    case Threading.resolve(Threading.candidate_ticket_ids(parsed, config), config) do
      {:existing, ticket} -> thread_onto(ticket, parsed, config)
      :new -> open_new(parsed, config)
    end
  end

  # --- thread onto an existing (same-org) ticket -----------------------------

  defp thread_onto(ticket, parsed, config) do
    if thread_message_count(ticket, config) >= config.max_inbound_per_thread do
      {:ok, %{disposition: :rate_capped, ticket_id: ticket.id}}
    else
      conversation = last_open_conversation(ticket, config) || create_conversation(ticket, config)
      contact_id = thread_contact_id(ticket, config) || upsert_contact(parsed, config)
      {:ok, message} = create_message(conversation, contact_id, parsed, config)

      {:ok,
       %{
         disposition: :threaded,
         ticket_id: ticket.id,
         conversation_id: conversation.id,
         message_id: message.id,
         contact_id: contact_id,
         auto_reply: :none
       }}
    end
  end

  # --- open a brand-new ticket -----------------------------------------------

  defp open_new(parsed, config) do
    subject = Sanitize.plain_text(parsed.subject) |> default_subject()

    # The ticket create is the ONLY step that can carry a uniqueness constraint (T60's
    # partial-unique `external_id` dedupe index). Propagate its error CLEANLY instead of
    # crashing on a hard match — a concurrent chat double-escalation's losing insert must
    # surface as `{:error, _}`, not an exception, so the caller can map it to a bounded
    # `:already_escalated`. For normal inbound (`external_id == nil`, no constraint)
    # create_ticket ALWAYS succeeds, so this is behaviourally identical to before (T59).
    case create_ticket(subject, config) do
      {:ok, ticket} ->
        {:ok, conversation} = create_conversation(ticket, config)
        contact_id = upsert_contact(parsed, config)
        {:ok, message} = create_message(conversation, contact_id, parsed, config)
        auto_reply = maybe_auto_reply(ticket, conversation, parsed, config)

        {:ok,
         %{
           disposition: :created,
           ticket_id: ticket.id,
           conversation_id: conversation.id,
           message_id: message.id,
           contact_id: contact_id,
           auto_reply: auto_reply
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- persistence (org_id pinned from trusted config, NEVER from the email) --

  defp create_ticket(subject, config) do
    attrs = %{
      subject: subject,
      status: :open,
      priority: :normal,
      org_id: config.org_id
    }

    # T60 (additive): a newly-opened ticket is BORN with the caller's external_id when
    # one is supplied (the chat-escalation dedupe key, set atomically at insert). Nil
    # for normal inbound → the attr stays nil (unconstrained by the partial index).
    attrs =
      case config.new_ticket_external_id do
        nil -> attrs
        ext -> Map.put(attrs, :external_id, ext)
      end

    config.ticket_resource
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(authorize?: false)
  end

  defp create_conversation(ticket, config) do
    config.conversation_resource
    |> Ash.Changeset.for_create(:create, %{
      channel: :email,
      status: :open,
      subject: ticket.subject,
      org_id: config.org_id,
      ticket_id: ticket.id
    })
    |> Ash.create(authorize?: false)
  end

  defp create_message(conversation, contact_id, parsed, config) do
    body = sanitized_body(parsed)
    attachment_keys = store_attachments(parsed, config)

    config.message_resource
    |> Ash.Changeset.for_create(:create, %{
      # body is 🔒 vault-routed (pii_body) — plaintext never lands at rest.
      body: body,
      sender_type: :customer,
      sender_id: contact_id,
      message_type: :reply,
      created_via: :email,
      attachments: attachment_keys,
      org_id: config.org_id,
      conversation_id: conversation.id
    })
    |> Ash.create(authorize?: false)
  end

  # --- vaulted contact (CRM Person) ------------------------------------------

  # Sender email + display name are PII → routed through the governed vault write path
  # (the Person resource's pii_attribute declarations → Samen.Vault.Change). Returns
  # the contact id (stored on Message.sender_id) or nil when no contact resource wired.
  defp upsert_contact(_parsed, %Config{contact_resource: nil}), do: nil

  defp upsert_contact(parsed, %Config{contact_resource: resource} = config) do
    display = Sanitize.plain_text(parsed.from_display) || parsed.from_address || "unknown sender"
    {first, last} = split_name(display)

    attrs = %{
      org_id: config.org_id,
      display_name: display,
      full_name: %Samen.Type.FullName{first: first, last: last}
    }

    attrs =
      if is_binary(parsed.from_address),
        do: Map.put(attrs, :emails, [%{label: "work", address: parsed.from_address}]),
        else: attrs

    case resource
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(authorize?: false) do
      {:ok, contact} -> contact.id
      {:error, _} -> nil
    end
  end

  defp split_name(display) do
    case String.split(display, ~r/\s+/, trim: true, parts: 2) do
      [first, last] -> {first, last}
      [only] -> {only, nil}
      _ -> {display, nil}
    end
  end

  # --- attachments (chokepoint) ----------------------------------------------

  defp store_attachments(_parsed, %Config{file_module: nil}), do: []

  defp store_attachments(parsed, %Config{file_module: mod, repo: repo} = config) do
    # Host-authored upload policy (allowed content types, size caps, scanner) is passed
    # through from config — the framework never invents a content-type allowlist.
    opts = Keyword.merge([file_module: mod, repo: repo], config.file_upload_opts || [])

    parsed.attachments
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn payload ->
      case Samen.Files.upload(%{org_id: config.org_id}, payload, opts) do
        {:ok, file} -> [file.storage_key]
        _ -> []
      end
    end)
  end

  # Accept an attachment already in `%{filename, content_type, binary}` shape (string
  # or atom keys); anything else is skipped (never crash on a hostile attachment blob).
  defp normalize_attachment(att) when is_map(att) do
    filename = att[:filename] || att["filename"] || att["Name"]
    content_type = att[:content_type] || att["content_type"] || att["ContentType"]
    binary = att[:binary] || att["binary"] || decode_content(att["Content"])

    if is_binary(filename) and is_binary(binary) do
      %{filename: filename, content_type: content_type || "application/octet-stream", binary: binary}
    else
      nil
    end
  end

  defp normalize_attachment(_), do: nil

  defp decode_content(nil), do: nil

  defp decode_content(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  defp decode_content(_), do: nil

  # --- auto-reply (loop-safe by construction) --------------------------------

  defp maybe_auto_reply(_ticket, _conversation, _parsed, %Config{auto_reply: nil}), do: :none

  defp maybe_auto_reply(ticket, conversation, parsed, %Config{auto_reply: fun} = config)
       when is_function(fun, 1) do
    # Loop-suppressed mail never reaches this point, so an auto-reply here can only be
    # for genuine human mail. We still stamp the loop-signal hint the SENDER should set
    # (Auto-Submitted: auto-replied) so the far side suppresses in turn.
    fun.(%{
      org_id: config.org_id,
      ticket_id: ticket.id,
      conversation_id: conversation.id,
      to: parsed.from_address,
      auto_submitted: "auto-replied"
    })

    :sent
  end

  # --- reads (org-scoped) ----------------------------------------------------

  defp last_open_conversation(ticket, config) do
    config.conversation_resource
    |> Ash.Query.filter(ticket_id == ^ticket.id and org_id == ^config.org_id and status == :open)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> read_one(config)
  end

  defp thread_contact_id(ticket, config) do
    conv_ids = conversation_ids(ticket, config)

    if conv_ids == [] do
      nil
    else
      config.message_resource
      |> Ash.Query.filter(conversation_id in ^conv_ids and org_id == ^config.org_id)
      |> Ash.Query.sort(inserted_at: :asc)
      |> Ash.Query.limit(1)
      |> read_one(config)
      |> case do
        nil -> nil
        message -> message.sender_id
      end
    end
  end

  defp thread_message_count(ticket, config) do
    case conversation_ids(ticket, config) do
      [] ->
        0

      conv_ids ->
        config.message_resource
        |> Ash.Query.filter(conversation_id in ^conv_ids and org_id == ^config.org_id)
        |> Ash.count(authorize?: false)
        |> case do
          {:ok, n} -> n
          _ -> 0
        end
    end
  end

  defp conversation_ids(ticket, config) do
    config.conversation_resource
    |> Ash.Query.filter(ticket_id == ^ticket.id and org_id == ^config.org_id)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, rows} -> Enum.map(rows, & &1.id)
      _ -> []
    end
  end

  defp read_one(query, _config) do
    case Ash.read_one(query, authorize?: false) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  # --- misc ------------------------------------------------------------------

  defp sanitized_body(parsed) do
    raw = parsed.text_body || parsed.html_body || ""
    Sanitize.plain_text(raw) |> default_body()
  end

  defp default_body(nil), do: "(no content)"
  defp default_body(""), do: "(no content)"
  defp default_body(s), do: s

  defp default_subject(nil), do: "(no subject)"
  defp default_subject(""), do: "(no subject)"
  defp default_subject(s), do: s
end
