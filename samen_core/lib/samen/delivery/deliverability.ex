defmodule Samen.Delivery.Deliverability do
  @moduledoc """
  The C4 deliverability-webhook DOMAIN HANDLER (ADR-038 §4.4; T30) — vendor-
  generic, family-agnostic (INV-4): it consumes a normalized
  `Samen.Delivery.ProviderEvent` (already parsed + redacted by the adapter) and:

    1. **Matches** the vendor `provider_message_id` to a send receipt
       (`%{send_id:, org_id:, subscriber_id:}`) via an injectable
       `:receipt_lookup` function — no adapter/host knowledge here, matching
       goes `provider_message_id -> send receipt -> subscriber ref`, NEVER by
       email address (ADR-038 §4.4).
    2. **Records** an `Samen.Delivery.EmailEvent` row for every matched
       `:delivered | :bounce | :complaint` event, and every `:open | :click`
       event that passes the consent-aware gate (§ below).
    3. **Suppresses**: `:bounce`/`:complaint` additionally write a
       `Samen.Delivery.Suppression` row — the SAME store
       `Samen.Delivery.SuppressionCheck` backs for the Chokepoint (ADR-038
       §4.3), so a bounced/complained address is refused on the NEXT send
       through the single chokepoint, not a second parallel enforcement point.
    4. **Unmatched events go to the DLQ**: `receipt_lookup` returning
       `:not_found` is an `{:error, :no_matching_receipt}` — the
       `Samen.Webhook.IngestWorker` retries per Oban policy, and on final
       exhaustion the envelope flips to `:dead` (operator-visible DLQ, §5.5).
       This is deliberately NOT a `{:discard, ...}` — a race where the send
       receipt hasn't landed yet before the webhook arrives is transient, so
       retrying (then DLQing if it never resolves) is the honest behavior.

  ## Open/click tracking — default OFF behind the consent-aware flag (c9)

  `:open`/`:click` events are recorded ONLY when BOTH gates pass:

    * the ORG-level feature flag `"delivery.open_click_tracking"`
      (`Samen.FeatureFlags.evaluate/2`) is ON — an flag the engine has never
      seen resolves OFF by construction (fail-SAFE default, RP-F4), so this is
      default-OFF with zero additional wiring (c9);
    * the injectable `:tracking_consent_module` reports the SPECIFIC
      `(org_id, subscriber_id)` pair as consented (`consented?/2`) — unwired
      degrades to `false` (the same "no check configured -> honest closed"
      posture `Samen.Delivery.Chokepoint.suppressed?/2` uses for the OPPOSITE
      direction; here "no consent recorded" must mean "don't track", not "ok
      to track").

  Both gates are asserted independently in the T30 test suite (flag OFF ->
  dropped even with consent; flag ON without consent -> STILL dropped; flag ON
  + consent -> recorded).

  ## Configuration

      config :samen_core, Samen.Delivery.Deliverability,
        receipt_lookup: Samen.Delivery.MarketingReceiptLookup.build(Demo.MarketingScope.Send),
        repo: Demo.Repo,
        tracking_consent_module: MyApp.DeliveryTrackingConsent  # optional; consented?/2
  """

  alias Samen.Delivery.{EmailEvent, ProviderEvent, Suppression}

  @recordable_kinds ~w(delivered bounce complaint open click)a
  @suppressing_kinds ~w(bounce complaint)a
  @tracking_kinds ~w(open click)a

  @doc """
  Handle one normalized deliverability event. `opts` (or config, opts win):

    * `:repo` — required to persist
    * `:receipt_lookup` — required arity-1 fun, `provider_message_id -> {:ok,
      receipt} | :not_found`
    * `:tracking_consent_module` — optional module implementing `consented?/2`

  Returns `:ok` (recorded, or honestly dropped — e.g. `:unhandled` kind, or an
  open/click event that failed the consent gate) or `{:error, reason}` (no
  matching receipt yet — retry, then DLQ).
  """
  @spec handle_event(ProviderEvent.t(), keyword()) :: :ok | {:error, term()}
  def handle_event(%ProviderEvent{kind: kind}, _opts) when kind not in @recordable_kinds do
    # :unhandled (or any future kind this handler doesn't yet know) — stored
    # replay-safe on the envelope already; nothing further to do (ADR-038 §3.3).
    :ok
  end

  def handle_event(%ProviderEvent{} = event, opts) do
    repo = fetch!(opts, :repo)
    receipt_lookup = fetch!(opts, :receipt_lookup)

    case receipt_lookup.(event.provider_message_id) do
      {:ok, receipt} -> handle_matched(event, receipt, repo, opts)
      :not_found -> {:error, :no_matching_receipt}
    end
  end

  defp handle_matched(%ProviderEvent{kind: kind} = event, receipt, repo, _opts)
       when kind in @suppressing_kinds do
    with {:ok, :inserted, _row} <- record(event, receipt, repo) do
      {:ok, _suppression} =
        Suppression.suppress(repo, %{
          org_id: receipt.org_id,
          subscriber_id: receipt.subscriber_id,
          reason: Atom.to_string(kind),
          source_provider: Atom.to_string(event.provider)
        })

      :ok
    else
      {:ok, :duplicate, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_matched(%ProviderEvent{kind: :delivered} = event, receipt, repo, _opts) do
    case record(event, receipt, repo) do
      {:ok, _status, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_matched(%ProviderEvent{kind: kind} = event, receipt, repo, opts)
       when kind in @tracking_kinds do
    if tracking_allowed?(receipt.org_id, receipt.subscriber_id, opts) do
      case record(event, receipt, repo) do
        {:ok, _status, _row} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      # Dropped at the handler — no EmailEvent row, per ADR-038 §4.4 (c9: the
      # consent-aware flag default-OFF path). Not an error: the webhook was
      # honestly processed, its outcome was "don't track".
      :ok
    end
  end

  defp record(%ProviderEvent{} = event, receipt, repo) do
    EmailEvent.record(repo, %{
      provider: Atom.to_string(event.provider),
      provider_event_id: event.event_id,
      provider_message_id: event.provider_message_id,
      kind: Atom.to_string(event.kind),
      send_id: receipt[:send_id],
      org_id: receipt.org_id,
      subscriber_id: receipt.subscriber_id,
      occurred_at: event.occurred_at
    })
  end

  # c9: BOTH the org-level flag (default OFF by construction) AND per-recipient
  # consent must hold.
  defp tracking_allowed?(org_id, subscriber_id, opts) do
    flag_on?(org_id, opts) and consented?(org_id, subscriber_id, opts)
  end

  # `:flag_evaluate_opts` threads through to `Samen.FeatureFlags.evaluate/3` —
  # in particular its `:loader` DI seam (the house
  # `feature_flags_engine_test.exs` convention), so this stays hermetic in
  # tests without needing a real FeatureFlag resource/DB row wired.
  defp flag_on?(org_id, opts) do
    flag_opts = Keyword.get(opts, :flag_evaluate_opts, [])
    Samen.FeatureFlags.evaluate("delivery.open_click_tracking", %{org_id: org_id}, flag_opts).on
  rescue
    # Fail-SAFE, matching the engine's own posture: any evaluation hiccup is OFF.
    _ -> false
  end

  defp consented?(org_id, subscriber_id, opts) do
    case tracking_consent_module(opts) do
      nil ->
        false

      mod ->
        try do
          mod.consented?(org_id, subscriber_id) == true
        rescue
          _ -> false
        end
    end
  end

  defp tracking_consent_module(opts) do
    Keyword.get(opts, :tracking_consent_module) ||
      Application.get_env(:samen_core, __MODULE__, [])[:tracking_consent_module]
  end

  defp fetch!(opts, key) do
    Keyword.get(opts, key) || Application.get_env(:samen_core, __MODULE__, [])[key] ||
      raise "Samen.Delivery.Deliverability: missing required #{inspect(key)} (pass as an opt or " <>
              "`config :samen_core, Samen.Delivery.Deliverability, #{key}: ...`)"
  end
end
