defmodule Samen.Support.Chat.Escalation do
  @moduledoc """
  The C6 offline-escalation capability (T60): when a live chat cannot be served, the
  conversation is handed off so the thread is never dropped — a support **Ticket**
  captures the transcript (org-scoped, vaulted, masked per plane) and an **email
  fallback** notifies the requester. Framework-first: this module lives in
  `samen_core`; a vertical adopts it at ≈0 authored LOC by handing an
  `Escalation.Config` its OWN Support/CRM resource modules (the first client is the
  demo support host — see `demo/test/support_chat_escalation_test.exs`).

  ## What it does NOT re-implement

  The chat→ticket write is delegated **verbatim** to the confirmed T59 path
  (`Samen.Support.Inbound.Ingest.ingest/2`): the transcript is projected into a
  synthesized `Samen.Delivery.InboundMessage` and ingested, inheriting T59's every
  governance property FOR FREE — `org_id` pinned from trusted config (NEVER derived
  from chat content), stored-XSS sanitized at rest, the message body 🔒 vault-routed
  and masked per plane, the requester upserted as a vaulted CRM contact. This module
  adds only the escalation-specific seams around that reuse:

    1. **Honest offline trigger** — `Samen.Support.Chat.Presence.evaluate/1` (pure;
       `agents_online` comes from a REAL presence source, never fabricated).
    2. **Idempotent bound (atomic at the DB)** — one ticket per chat, keyed on the
       ticket's `external_id == "chat:<thread_ref>"` (org-scoped). The ticket is BORN
       with that `external_id` at insert time and a partial-unique index on
       `(org_id, external_id) WHERE external_id IS NOT NULL` (see the Support Ticket
       blueprint's `unique_index_names` + the host migration) makes a CONCURRENT
       double-escalation structurally impossible: exactly one insert wins, the loser
       collides on the constraint, re-reads the winner, and returns `:already_escalated`
       — NO second ticket, NO second email. A cheap pre-write read short-circuits the
       common sequential repeat. Sabotage: drop the index and a barrier-synced race
       yields 2 tickets + 2 emails.
    3. **Email fallback** — a TOKEN-ONLY `Samen.Delivery.Message` through
       `Samen.Delivery.Chokepoint.send/2` (the single send chokepoint). Fail-honest:
       an unconfigured provider surfaces `{:error, :not_configured}` (never a faked
       `{:ok, _}`). The envelope carries NO chat plaintext and NO other party's PII —
       only opaque ids; the recipient email is vault-revealed at delivery time.
    4. **T41 escalation primitive** — a best-effort `Samen.Automation.Escalate.open/2`
       (idempotent-by-dedupe on `{org_id, kind, dedupe_key}`) for the timer/chain/audit
       trail, wrapped so an unwired/failing automation module never aborts the handoff
       (mirrors `SlaBreachWorker`'s adoption posture).

  ## Cross-plane / masking (INV-1 + INV-2)

  Escalation captures on the tenant/system plane (full transcript) and VAULTS it into
  the ticket message body; per-viewer masking then applies downstream — an operator
  without a grant viewing the escalated ticket sees `••••`, never the plaintext, never
  a `vt_` token (proven by the MaskingCase 3-proof in the demo gate). The email
  envelope is token-only, so no plane's PII crosses into the other plane's mail.

  ## Entry points

    * `evaluate/1` — delegates to `Presence.evaluate/1` (the honest trigger).
    * `escalate/2` — perform the handoff (idempotent). Returns
      `{:ok, %{disposition: :escalated | :already_escalated, ...}}` or `{:error, _}`.
    * `maybe_escalate/2` — `evaluate/1` then `escalate/2` only when it says escalate.
  """

  require Logger

  alias Samen.Delivery.{Chokepoint, InboundMessage, Message}
  alias Samen.Support.Chat.{Config, Presence, Transcript}
  alias Samen.Support.Inbound

  @doc "The honest offline/unserved decision (delegates to `Presence.evaluate/1`)."
  @spec evaluate(map()) :: :serve | {:escalate, Presence.reason()}
  defdelegate evaluate(signal), to: Presence

  @doc """
  Evaluate the honest trigger, then escalate only when unserved. Returns
  `{:ok, :served}` when the chat can still be served (no handoff), otherwise the
  `escalate/2` result. `ctx` must carry the presence `:signal` (see `Presence`).
  """
  @spec maybe_escalate(map(), Config.t()) :: {:ok, :served} | {:ok, map()} | {:error, term()}
  def maybe_escalate(ctx, %Config{} = config) do
    case evaluate(Map.get(ctx, :signal, %{})) do
      :serve -> {:ok, :served}
      {:escalate, reason} -> escalate(Map.put(ctx, :reason, reason), config)
    end
  end

  @doc """
  Perform the escalation for one chat, IDEMPOTENTLY.

  `ctx`:

    * `:thread_ref` (req) — the chat thread/session id; the idempotency + dedupe key
    * `:entries` — transcript entries (see `Samen.Support.Chat.Transcript`)
    * `:requester` — `%{address, display_name, subscriber_id}` (all optional; a nil
      `subscriber_id` means we have no verified recipient → email `{:error, :no_recipient}`)
    * `:reason` — the escalation reason atom (from `evaluate/1`), for the audit trail

  Returns:

    * `{:ok, %{disposition: :escalated, ticket_id, conversation_id, message_id,
      contact_id, email:, escalation:, reason:}}` — first escalation
    * `{:ok, %{disposition: :already_escalated, ticket_id, email: :skipped}}` — repeat
    * `{:error, reason}` — a real failure (never a fabricated success)
  """
  @spec escalate(map(), Config.t()) :: {:ok, map()} | {:error, term()}
  def escalate(ctx, %Config{} = config) do
    # NB: there is deliberately NO pre-write "does a ticket already exist?" read here.
    # A pre-read is a TOCTOU window (two racers both read :none, both create) — the exact
    # defect this fix removes. The SOLE idempotency arbiter is the atomic ticket create
    # against the partial-unique `external_id` index (see `do_escalate/3`): every escalate
    # attempts the create; the loser collides and is mapped to `:already_escalated` by a
    # re-read of the winner. This makes both the sequential AND concurrent paths converge
    # on the DB constraint, so the sabotage (drop the index) reliably yields 2 tickets.
    case fetch_ref(ctx) do
      nil -> {:error, :missing_thread_ref}
      ref -> do_escalate(ctx, config, ref)
    end
  end

  # ---------------------------------------------------------------------------

  defp do_escalate(ctx, config, ref) do
    entries = Map.get(ctx, :entries, [])
    requester = Map.get(ctx, :requester, %{})

    # The ticket is BORN carrying `external_id == "chat:<ref>"` ATOMICALLY at insert
    # (threaded through the T59 create) — the create is the race point. The partial-
    # unique index arbitrates a concurrent double-escalation: exactly ONE insert wins.
    case ingest_transcript(entries, requester, config, ref) do
      {:ok, ingested} ->
        # WON the create. ONLY the winner opens the timer record + sends the fallback
        # email — the email is strictly downstream of a successful atomic create, so a
        # loser can never fire a second email.
        escalation = open_escalation_record(config, ref, Map.get(ctx, :reason, :offline))
        email = deliver_fallback(requester, config)

        {:ok,
         %{
           disposition: :escalated,
           ticket_id: ingested.ticket_id,
           conversation_id: ingested.conversation_id,
           message_id: ingested.message_id,
           contact_id: ingested.contact_id,
           email: email,
           escalation: escalation,
           reason: Map.get(ctx, :reason)
         }}

      {:error, reason} ->
        # LOST the create — either the unique-index collision (a concurrent racer beat
        # us) or a genuine failure. Distinguish by re-reading the winner (org-scoped): if
        # the escalation ticket now exists, this is a bounded duplicate → the SAME clean
        # `:already_escalated` outcome, sending NOTHING. Otherwise surface the real error.
        case find_existing(config, ref) do
          {:ok, ticket} ->
            {:ok, %{disposition: :already_escalated, ticket_id: ticket.id, email: :skipped}}

          :none ->
            {:error, reason}
        end
    end
  end

  # --- chat -> ticket: REUSE the confirmed T59 ingest path verbatim -----------

  defp ingest_transcript(entries, requester, config, ref) do
    body = Transcript.render(entries)
    subject = Transcript.subject(entries)

    inbound = %InboundMessage{
      provider: :chat,
      message_id: "chat-escalation-#{Ash.UUID.generate()}",
      from: get(requester, :address),
      from_name: get(requester, :display_name),
      subject: subject,
      text_body: body,
      headers: %{},
      attachments: []
    }

    case Inbound.Ingest.ingest(inbound, inbound_config(config, ref)) do
      {:ok, %{ticket_id: _} = result} -> {:ok, result}
      {:ok, other} -> {:error, {:unexpected_ingest_disposition, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The ticket is born with `external_id` at insert time via `new_ticket_external_id`
  # (the atomic dedupe seam threaded through the T59 create).
  defp inbound_config(%Config{} = config, ref) do
    Inbound.Config.new(
      org_id: config.org_id,
      repo: config.repo,
      ticket_resource: config.ticket_resource,
      conversation_resource: config.conversation_resource,
      message_resource: config.message_resource,
      contact_resource: config.contact_resource,
      our_domains: config.our_domains,
      our_addresses: config.our_addresses,
      inbound_localpart: config.inbound_localpart,
      new_ticket_external_id: dedupe_id(ref)
    )
  end

  # --- idempotency: one ticket per chat, org-scoped ---------------------------

  defp find_existing(%Config{} = config, ref) do
    require Ash.Query

    config.ticket_resource
    |> Ash.Query.filter(external_id == ^dedupe_id(ref) and org_id == ^config.org_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [ticket]} -> {:ok, ticket}
      _ -> :none
    end
  end

  defp dedupe_id(ref), do: "chat:" <> to_string(ref)

  # --- T41 escalation primitive (best-effort; never aborts the handoff) -------

  @doc """
  Open (or advance) the T41 escalation record for this chat via
  `Samen.Automation.Escalate.open/2` — the E5 generic primitive, idempotent-by-dedupe
  on `{org_id, "chat_offline", thread_ref}`. This is the SAME seam `escalate/2` uses
  internally (exposed so the primitive integration is provable in isolation). It is
  BEST-EFFORT: an unwired (`escalation_module: nil`) config returns `:skipped`, and a
  failing/raising automation module is caught — the escalation handoff (ticket + email)
  is NEVER aborted by the timer-record's absence (mirrors `SlaBreachWorker`'s posture).
  """
  @spec open_escalation_record(Config.t(), term(), atom()) ::
          :skipped | {:opened, atom()} | {:error, term()} | :error
  def open_escalation_record(%Config{escalation_module: nil}, _ref, _reason), do: :skipped

  def open_escalation_record(%Config{} = config, ref, reason) do
    now = DateTime.utc_now()
    deadline = DateTime.add(now, config.sla_seconds, :second)

    attrs = %{
      org_id: config.org_id,
      kind: "chat_offline",
      dedupe_key: to_string(ref),
      subject_ref: "samen:chat.thread:" <> to_string(ref),
      deadline_at: deadline,
      chain: config.escalation_chain
    }

    opts =
      [escalation_module: config.escalation_module]
      |> maybe_put(:repo, config.escalation_repo)

    case Samen.Automation.Escalate.open(attrs, opts) do
      {:ok, _escalation} ->
        {:opened, reason}

      {:error, err} ->
        Logger.warning("[Chat.Escalation] automation escalate best-effort failed: #{inspect(err)}")
        {:error, err}
    end
  rescue
    e ->
      Logger.warning("[Chat.Escalation] automation escalate raised: #{Exception.message(e)}")
      :error
  end

  # --- email fallback: token-only, fail-honest, through the send chokepoint ---

  defp deliver_fallback(requester, %Config{} = config) do
    case get(requester, :subscriber_id) do
      nil ->
        {:error, :no_recipient}

      subscriber_id ->
        message = %Message{
          send_id: Ash.UUID.generate(),
          org_id: config.org_id,
          to_subscriber_id: to_string(subscriber_id),
          template_id: config.escalation_template_id
        }

        opts =
          [env: config.delivery_env]
          |> maybe_put(:fallback_adapter, config.fallback_adapter)
          |> maybe_put(:fallback_config, config.fallback_config)

        normalize_send(Chokepoint.send(message, opts))
    end
  end

  # The capability's fail-honest contract surface: the chokepoint's honest
  # "unconfigured" signal is `:adapter_unconfigured`; T60's documented contract (and
  # the CLAUDE.md precedent — Delivery.Smtp / Files.Storage.S3) is `:not_configured`.
  # Normalize at the boundary. NEVER a fabricated `{:ok, _}`.
  defp normalize_send({:ok, receipt}), do: {:ok, receipt}
  defp normalize_send({:error, :adapter_unconfigured}), do: {:error, :not_configured}
  defp normalize_send({:error, reason}), do: {:error, reason}

  # --- misc -------------------------------------------------------------------

  defp fetch_ref(ctx) do
    case Map.get(ctx, :thread_ref) || Map.get(ctx, "thread_ref") do
      ref when is_binary(ref) and ref != "" -> ref
      ref when is_integer(ref) -> Integer.to_string(ref)
      _ -> nil
    end
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp get(_, _), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
