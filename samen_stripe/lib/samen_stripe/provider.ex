defmodule SamenStripe.Provider do
  @moduledoc """
  Stripe implementation of `Samen.Billing.Provider` — **SKELETON** (ADR-038 §3;
  T18/B1). Every callback is present and honest:

    * `configured?/1` is `true` only when `config[:secret_key]` is a present,
      non-empty string.
    * Every other callback (except `redact_payload/1`) returns
      `{:error, :not_configured}` when `configured?/1` is `false` for the same
      config, and `{:error, :not_implemented}` when configured but not yet wired
      — the real Stripe HTTP dispatch (via `Req`) and the Stripe webhook signature
      scheme are operator/T19–T21 work, NOT faked here (mirrors the
      `Samen.Delivery.Smtp` skeleton precedent: never a fake `{:ok, _}`).
    * `redact_payload/1` is pure and does REAL work now — it does not need creds,
      so it runs regardless of `configured?/1`.

  This module is the ONLY place in this package (indeed, in the whole adapter
  tree) that references Stripe by name — `samen_core`/`samen_web` never do
  (INV-4, ADR-038 §8).
  """

  @behaviour Samen.Billing.Provider

  alias Samen.Billing.ProviderEvent

  # ALLOWLIST redaction (T24 hardening; ADR-038 §5.4 / INV-1). Stripe's
  # `metadata` bag is FREE-FORM, org-authored key/value data — a merchant can
  # put literally anything under ANY key (`metadata.account_holder_ssn`,
  # `metadata.support_contact_email`, an internal case-note field, …). The
  # ORIGINAL implementation here was a DENYLIST of ~8 known-bad key names
  # (`email name phone address billing_details shipping receipt_email
  # customer_email`), recursively applied into nested maps — so it DID catch a
  # nested key that happened to literally match one of those 8 names, but it
  # MISSES by construction the moment PII lands under any OTHER, unenumerated
  # key (`metadata.account_holder_ssn`, a differently-named contact-email
  # field, …) — a denylist can only ever enumerate the keys someone thought of
  # in advance (the T19 verifier's flag).
  #
  # The allowlist inverts the failure mode: a top-level field survives ONLY IF
  # (a) its name is on `@safe_keys` AND (b) its value is a plain SCALAR — an
  # expanded/nested value under an allowlisted key (e.g. an expanded `customer`
  # object that itself carries an email) is ALSO dropped, never assumed safe
  # merely because the key name is safe. `metadata` — and every other nested
  # map/list (`billing_details`, `customer_details`, `shipping`, `address`, the
  # `discount`/`tax_rate` sub-objects, …) — is dropped WHOLESALE, never
  # selectively descended into: nothing downstream needs it. The `org_id`/
  # `plan_id` refs samen itself stamps into `metadata` at checkout time are
  # recovered from the RAW (pre-redaction) body by
  # `SamenStripe.Provider.extract_refs/1` / `Samen.Billing.WebhookDispatch`'s
  # ref-recovery — never from this stored, redacted `payload`.
  @safe_keys ~w(
    id object status currency amount amount_due amount_paid amount_total
    amount_remaining amount_captured amount_refunded quantity mode
    payment_status created period_start period_end current_period_start
    current_period_end due_date trial_end cancel_at canceled_at
    cancel_at_period_end next_payment_attempt attempt_count livemode
    delinquent tax number customer subscription invoice payment_intent
    charge latest_invoice
  )a
  @safe_string_keys Enum.map(@safe_keys, &Atom.to_string/1)

  # Stripe's replay-tolerance window for webhook signatures (their recommended 5 min).
  @signature_tolerance_seconds 300

  # Stripe vendor event `type` → the bounded, samen-owned `ProviderEvent` kind enum
  # (ADR-038 §3.3). Anything not listed maps to `:unhandled` (stored replay-safe, not
  # dispatched).
  @kind_map %{
    "checkout.session.completed" => :checkout_completed,
    "checkout.session.expired" => :checkout_expired,
    "customer.subscription.created" => :subscription_created,
    "customer.subscription.updated" => :subscription_updated,
    "customer.subscription.deleted" => :subscription_deleted,
    "invoice.finalized" => :invoice_finalized,
    "invoice.paid" => :invoice_paid,
    "invoice.payment_failed" => :invoice_payment_failed,
    "payment_method.attached" => :payment_method_attached,
    "payment_method.detached" => :payment_method_detached
  }

  @impl true
  def configured?(config) when is_map(config) do
    present?(config, :secret_key)
  end

  def configured?(_), do: false

  # B2 (T20) — hosted checkout session creation. `attrs` (already validated + org-scoped
  # by the core `Samen.Billing.Checkout.create_session/2`): `%{org_id, plan_id,
  # price_ref, success_url, cancel_url, customer_ref (optional)}`. `org_id`/`plan_id`
  # travel in Stripe `metadata` (NOT PII — opaque samen ids) so the `checkout.session.completed`
  # webhook can recover them (redaction never strips `metadata`, only PII-bearing keys).
  # No card/PII data is ever sent — the ONLY fields on the wire are the ADR-listed attrs
  # (INV-1, snapshot-tested in samen_stripe/test/checkout_test.exs).
  @impl true
  def create_checkout_session(attrs, config) do
    if configured?(config) do
      do_create_checkout_session(attrs, config)
    else
      {:error, :not_configured}
    end
  end

  # B5 (T23) — payment methods via a Stripe-HOSTED billing-portal session URL
  # ONLY (ADR-038 §3.5 no-PAN rule). `attrs` (already validated + whitelisted by
  # the core `Samen.Billing.PaymentMethod.create_portal_session/2`): `%{org_id,
  # customer_ref, return_url, billing_name (optional), billing_email
  # (optional)}`. When `billing_name`/`billing_email` are present (the core's
  # vault-RESOLVED customer-sync fields, ADR-038 §3.5 whitelist), they are
  # synced to the Stripe customer object FIRST via a HARDCODED name/email-only
  # form (`customer_sync_form/1` below — never attrs-driven, so no caller can
  # smuggle an extra field onto the wire even if the core whitelist were ever
  # weakened) — this is the "customer sync" done-criterion 3 names. The portal
  # session itself carries ONLY `customer`/`return_url` — no PAN, no PII, ever
  # (done-criterion 2: the returned `url` is ALWAYS Stripe's own hosted
  # `billing_portal` URL, never a samen-rendered card form).
  @impl true
  def create_portal_session(attrs, config) do
    if configured?(config) do
      do_create_portal_session(attrs, config)
    else
      {:error, :not_configured}
    end
  end

  # B3 (T21) — samen-initiated cancel. `opts[:at_period_end]` (default true) schedules
  # the cancel at period end (grace) via `cancel_at_period_end=true`; `false` cancels
  # immediately (DELETE). Returns the normalized, updated subscription snapshot so the
  # caller mirrors provider truth (never a locally-invented state).
  @impl true
  def cancel_subscription(provider_subscription_id, opts, config) do
    if configured?(config) do
      at_period_end = Keyword.get(opts, :at_period_end, true)
      do_cancel_subscription(provider_subscription_id, at_period_end, config)
    else
      {:error, :not_configured}
    end
  end

  # B3 (T21) — samen-initiated plan/price change with a proration behavior. `changes`:
  # `%{price_ref: "price_...", proration_behavior: "create_prorations" | "none" | ...,
  # item_id: "si_..."}`. Returns the normalized, updated subscription snapshot (with the
  # proration Stripe computed, MIRRORED — never recomputed here).
  @impl true
  def change_subscription(provider_subscription_id, changes, config) do
    if configured?(config) do
      do_change_subscription(provider_subscription_id, changes, config)
    else
      {:error, :not_configured}
    end
  end

  # B3 (T21) / B4+B6 (T22) — the convergence primitive (ADR-038 §3.4). Authoritative
  # re-fetch of a provider object, normalized to samen field names. `:subscription`
  # is the B3 object; `:customer` supports the create/customer-resolution path;
  # `:invoice` (T22) mirrors amounts/tax/status/hosted links. `:payment_method_summary`
  # (T23) is honestly not-yet-served HERE (fail-honest — its owner wires it), never a
  # fake success.
  @impl true
  def fetch_object(kind, provider_id, config) do
    cond do
      not configured?(config) -> {:error, :not_configured}
      kind == :subscription -> do_fetch_subscription(provider_id, config)
      kind == :customer -> do_fetch_customer(provider_id, config)
      kind == :invoice -> do_fetch_invoice(provider_id, config)
      true -> {:error, :not_implemented}
    end
  end

  # B8 (T25) — metered usage reporting (ADR-038 §3.1 `report_usage/2` +
  # idempotency-key rule). `batch` items come from `Samen.Billing.UsageReporter`
  # (vendor-generic core): `%{usage_record_id, idempotency_key, quantity,
  # timestamp, subscription_id, provider_ref}`. `provider_ref` is the
  # subscription-item id Stripe's classic metered-billing endpoint requires
  # (`POST /v1/subscription_items/:id/usage_records`) — this codebase's
  # Subscription mirror does not yet model per-item refs separately from
  # `provider_subscription_ref` (documented GAP, see the moduledoc note below), so
  # the mirror-supplied `provider_ref` is passed through VERBATIM as the item id;
  # a production usage mirror wiring a real subscription-item ref is the T25-G2
  # follow-up.
  #
  # Reported ATOMICALLY at the batch level (never partial): the first per-record
  # HTTP call that fails halts the whole call with `{:error, reason}` — the core
  # `UsageReporter` marks NOTHING on any error, so a retry safely re-sends the
  # ENTIRE batch. That retry is safe (not a double-bill) precisely because each
  # record's `idempotency_key` (`"usage:" <> usage_record_id`, derived by the
  # core, unchanged across retries) is sent as Stripe's `Idempotency-Key` header
  # — Stripe dedups any record it already durably processed before the failure.
  @impl true
  def report_usage(batch, config) when is_list(batch) do
    if configured?(config) do
      do_report_usage(batch, config)
    else
      {:error, :not_configured}
    end
  end

  @impl true
  def verify_and_parse_event(raw_body, headers, config)
      when is_binary(raw_body) and is_list(headers) do
    cond do
      # Fail-honest: an unconfigured provider refuses (ADR-038 §3.2).
      not configured?(config) ->
        {:error, :not_configured}

      # Configured for the API but the webhook signing secret is not wired: the
      # verification capability is genuinely not available — the honest absence, never
      # a fake accept (ADR-014 / ADR-038 §3.2).
      not present?(config, :webhook_secret) ->
        {:error, :not_implemented}

      true ->
        do_verify_and_parse(raw_body, headers, Map.fetch!(config, :webhook_secret))
    end
  end

  def verify_and_parse_event(_raw_body, _headers, config), do: guarded(config)

  # The Stripe signature scheme is `Stripe-Signature: t=<ts>,v1=<HMAC-SHA256(secret,
  # "<ts>.<body>")>` — byte-for-byte the shape the core `Samen.Webhook.Signer` verify
  # primitive already implements (delegating the crypto to the vendor-generic core
  # primitive, ADR-038 §5). Vendor-specific work HERE is only: which header carries the
  # signature, the event-name → kind mapping, ref extraction, and PII redaction.
  defp do_verify_and_parse(raw_body, headers, secret) do
    case find_header(headers, "stripe-signature") do
      nil ->
        {:error, :malformed}

      sig_header ->
        case Samen.Webhook.Signer.verify(
               raw_body,
               sig_header,
               secret,
               @signature_tolerance_seconds
             ) do
          {:ok, _timestamp} -> parse_event(raw_body)
          {:error, :bad_signature} -> {:error, :invalid_signature}
          {:error, :stale_timestamp} -> {:error, :stale_timestamp}
          {:error, :malformed_header} -> {:error, :malformed}
        end
    end
  end

  defp parse_event(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"id" => id, "type" => type} = body} when is_binary(id) ->
        {:ok,
         %ProviderEvent{
           provider: :stripe,
           event_id: id,
           kind: Map.get(@kind_map, type, :unhandled),
           occurred_at: parse_occurred_at(body),
           provider_refs: extract_refs(body),
           # The envelope is persisted with PII ALREADY pruned (INV-1, ADR-038 §5.4).
           payload: redact_payload(inner_object(body))
         }}

      _ ->
        {:error, :malformed}
    end
  end

  defp inner_object(body) do
    case get_in(body, ["data", "object"]) do
      obj when is_map(obj) -> obj
      _ -> body
    end
  end

  defp parse_occurred_at(%{"created" => created}) when is_integer(created) do
    case DateTime.from_unix(created) do
      {:ok, dt} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_occurred_at(_), do: DateTime.utc_now()

  defp extract_refs(body) do
    obj = inner_object(body)
    metadata = obj["metadata"] || %{}

    %{}
    |> put_ref(:object_id, obj["id"])
    |> put_ref(:customer_id, obj["customer"])
    |> put_ref(:subscription_id, obj["subscription"])
    |> put_ref(:org_id, metadata["org_id"])
    |> put_ref(:plan_id, metadata["plan_id"])
  end

  defp put_ref(refs, _key, nil), do: refs
  defp put_ref(refs, key, value) when is_binary(value), do: Map.put(refs, key, value)
  defp put_ref(refs, _key, _value), do: refs

  defp find_header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v, else: nil
    end)
  end

  @impl true
  def redact_payload(payload) when is_map(payload) do
    payload
    |> Enum.filter(fn {k, v} -> allowed_key?(k) and scalar?(v) end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # B3 lifecycle sync (T21) — Stripe REST calls + normalization to samen field names.
  # ---------------------------------------------------------------------------

  @api_base "https://api.stripe.com"

  # Stripe subscription `status` → the samen-owned bounded enum (matches the
  # Billing.Subscription `status` constraint). Unknown/incomplete/paused → :inactive.
  @status_map %{
    "active" => :active,
    "trialing" => :trialing,
    "past_due" => :past_due,
    "canceled" => :cancelled,
    "unpaid" => :unpaid
  }

  # B2 (T20) — hosted checkout session creation. Required attrs (mirrors the ADR-038
  # §3.1 callback doc): org_id, plan_id, price_ref, success_url, cancel_url.
  # `customer_ref` is OPTIONAL (Stripe auto-creates an anonymous customer at checkout
  # time when absent) — no PAN/email/name is EVER part of this form (INV-1).
  @checkout_required_attrs [:org_id, :plan_id, :price_ref, :success_url, :cancel_url]

  defp do_create_checkout_session(attrs, config) do
    case checkout_form(attrs) do
      {:ok, form} ->
        url = @api_base <> "/v1/checkout/sessions"

        case request(:post, url, config, form) do
          {:ok, %{status: 200, body: body}} ->
            case decode(body) do
              {:ok, %{"id" => id, "url" => session_url}} ->
                {:ok, %{provider_session_id: id, url: session_url}}

              _ ->
                {:error, :malformed}
            end

          {:ok, %{status: status}} ->
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, _reason} = err ->
        err
    end
  end

  defp checkout_form(attrs) do
    missing = Enum.filter(@checkout_required_attrs, &blank_attr?(attrs, &1))

    if missing != [] do
      {:error, {:missing_attrs, missing}}
    else
      form =
        %{
          "mode" => "subscription",
          "line_items[0][price]" => attr(attrs, :price_ref),
          "line_items[0][quantity]" => "1",
          "success_url" => attr(attrs, :success_url),
          "cancel_url" => attr(attrs, :cancel_url),
          "metadata[org_id]" => attr(attrs, :org_id),
          "metadata[plan_id]" => attr(attrs, :plan_id)
        }
        |> maybe_put_customer(attrs)

      {:ok, form}
    end
  end

  defp maybe_put_customer(form, attrs) do
    case attr(attrs, :customer_ref) do
      nil -> form
      "" -> form
      customer_ref -> Map.put(form, "customer", customer_ref)
    end
  end

  defp attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp blank_attr?(attrs, key) do
    case attr(attrs, key) do
      nil -> true
      "" -> true
      _ -> false
    end
  end

  # B5 (T23) — required attrs for a hosted portal session (mirrors the
  # `checkout_form`/`@checkout_required_attrs` shape above).
  @portal_required_attrs [:customer_ref, :return_url]

  defp do_create_portal_session(attrs, config) do
    missing = Enum.filter(@portal_required_attrs, &blank_attr?(attrs, &1))

    if missing != [] do
      {:error, {:missing_attrs, missing}}
    else
      with :ok <- maybe_sync_customer(attrs, config) do
        url = @api_base <> "/v1/billing_portal/sessions"

        form = %{
          "customer" => attr(attrs, :customer_ref),
          "return_url" => attr(attrs, :return_url)
        }

        case request(:post, url, config, form) do
          {:ok, %{status: 200, body: body}} ->
            case decode(body) do
              {:ok, %{"url" => hosted_url}} -> {:ok, %{url: hosted_url}}
              _ -> {:error, :malformed}
            end

          {:ok, %{status: status}} ->
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  # The B5 customer-sync HALF of done-criterion 3: sync `billing_name`/
  # `billing_email` (the core's vault-RESOLVED, ADR-038 §3.5-whitelisted
  # fields) onto the Stripe customer object BEFORE creating the portal
  # session, so the hosted portal shows the tenant's real name/email rather
  # than whatever stale value Stripe already has. `customer_sync_form/1` is a
  # HARDCODED name/email-only builder — it reads ONLY `:billing_name`/
  # `:billing_email` off `attrs` and NEVER any other key, so this whitelist
  # holds even if a caller's `attrs` map somehow carried more (a second,
  # independent whitelist on top of the core's own — no single point of
  # failure). Absent both -> a pure no-op (`:ok`, no wasted round-trip).
  defp maybe_sync_customer(attrs, config) do
    case customer_sync_form(attrs) do
      form when map_size(form) == 0 ->
        :ok

      form ->
        url = @api_base <> "/v1/customers/" <> attr(attrs, :customer_ref)

        case request(:post, url, config, form) do
          {:ok, %{status: 200}} -> :ok
          {:ok, %{status: status}} -> {:error, {:http_error, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp customer_sync_form(attrs) do
    %{}
    |> put_sync_field("name", attr(attrs, :billing_name))
    |> put_sync_field("email", attr(attrs, :billing_email))
  end

  defp put_sync_field(form, _key, nil), do: form
  defp put_sync_field(form, _key, ""), do: form
  defp put_sync_field(form, key, value) when is_binary(value), do: Map.put(form, key, value)
  defp put_sync_field(form, _key, _value), do: form

  defp do_fetch_subscription(id, config) do
    url = @api_base <> "/v1/subscriptions/" <> id <> "?expand[]=latest_invoice"

    case request(:get, url, config) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, obj} -> {:ok, normalize_subscription(obj)}
          :error -> {:error, :malformed}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fetch_customer(id, config) do
    url = @api_base <> "/v1/customers/" <> id

    case request(:get, url, config) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, obj} -> {:ok, normalize_customer(obj)}
          :error -> {:error, :malformed}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # B4+B6 (T22). `expand[]=charge` so a paid invoice's hosted RECEIPT link is
  # available in ONE round-trip (§ receipt_url/3 below) — the same "one expand,
  # one fetch" shape `do_fetch_subscription/2` uses for `latest_invoice`.
  defp do_fetch_invoice(id, config) do
    url = @api_base <> "/v1/invoices/" <> id <> "?expand[]=charge"

    case request(:get, url, config) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, obj} -> {:ok, normalize_invoice(obj)}
          :error -> {:error, :malformed}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # B8 usage reporting (T25) — Stripe's classic per-subscription-item metered
  # endpoint. ATOMIC at the batch level: the first failing record halts with
  # {:error, reason}; nothing already-succeeded is trusted as "safe" by this
  # module — the caller (Samen.Billing.UsageReporter) marks nothing on any
  # error, and a retry is safe because the idempotency key is stable.
  # ---------------------------------------------------------------------------

  defp do_report_usage([], _config), do: {:ok, %{reported: 0}}

  defp do_report_usage(batch, config) do
    batch
    |> Enum.reduce_while({:ok, 0}, fn item, {:ok, count} ->
      case post_usage_record(item, config) do
        {:ok, _obj} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, count} -> {:ok, %{reported: count}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_usage_record(item, config) do
    case Map.get(item, :provider_ref) do
      ref when ref in [nil, ""] -> {:error, :missing_provider_ref}
      ref -> do_post_usage_record(ref, item, config)
    end
  end

  defp do_post_usage_record(provider_ref, item, config) do
    url = @api_base <> "/v1/subscription_items/" <> provider_ref <> "/usage_records"

    form = %{
      "quantity" => Map.get(item, :quantity),
      "timestamp" => to_unix_ts(Map.get(item, :timestamp)),
      "action" => "increment"
    }

    case request(:post, url, config, form, idempotency_key: Map.get(item, :idempotency_key)) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, obj} -> {:ok, obj}
          :error -> {:error, :malformed}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_unix_ts(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix_ts(ts) when is_integer(ts), do: ts
  defp to_unix_ts(_), do: System.os_time(:second)

  defp do_cancel_subscription(id, true, config) do
    # Scheduled cancel (grace): keep the subscription live until period end.
    url = @api_base <> "/v1/subscriptions/" <> id <> "?expand[]=latest_invoice"
    post_subscription(url, %{"cancel_at_period_end" => true}, config)
  end

  defp do_cancel_subscription(id, false, config) do
    # Immediate cancel: Stripe DELETE returns the canceled subscription object.
    url = @api_base <> "/v1/subscriptions/" <> id <> "?expand[]=latest_invoice"

    case request(:delete, url, config) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, obj} -> {:ok, normalize_subscription(obj)}
          :error -> {:error, :malformed}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_change_subscription(id, changes, config) do
    url = @api_base <> "/v1/subscriptions/" <> id <> "?expand[]=latest_invoice"
    post_subscription(url, change_form(changes), config)
  end

  # Build the Stripe form for a plan/price change. Stripe requires the target
  # subscription item id + the new price; `proration_behavior` is passed through so the
  # CALLER chooses the proration policy (samen never invents it).
  defp change_form(changes) do
    %{}
    |> put_form("items[0][id]", changes[:item_id] || changes["item_id"])
    |> put_form("items[0][price]", changes[:price_ref] || changes["price_ref"])
    |> put_form(
      "proration_behavior",
      changes[:proration_behavior] || changes["proration_behavior"]
    )
  end

  defp put_form(form, _k, nil), do: form
  defp put_form(form, k, v), do: Map.put(form, k, v)

  defp post_subscription(url, form, config) do
    case request(:post, url, config, form) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, obj} -> {:ok, normalize_subscription(obj)}
          :error -> {:error, :malformed}
        end

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The injectable transport: config[:transport] REPLACES the real Req transport for
  # hermetic tests (ADR-038 §7.1 lane 0). Same shape as SamenPostmark.
  #
  # `opts[:idempotency_key]` (T25/B8) rides in the SAME request map every
  # transport (real + injected) already receives — `SamenStripe.Transport.live/1`
  # turns a present key into Stripe's `Idempotency-Key` HTTP header; a hermetic
  # test's capturing transport can assert on it directly off the map, no header
  # parsing needed.
  defp request(method, url, config, form \\ %{}, opts \\ []) do
    transport = Map.get(config, :transport) || (&SamenStripe.Transport.live/1)

    transport.(%{
      method: method,
      url: url,
      secret_key: Map.get(config, :secret_key),
      form: form,
      idempotency_key: Keyword.get(opts, :idempotency_key)
    })
  end

  defp decode(body) when is_map(body), do: {:ok, body}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, obj} when is_map(obj) -> {:ok, obj}
      _ -> :error
    end
  end

  defp decode(_), do: :error

  # Normalize a Stripe subscription object to the vendor-neutral snapshot the core
  # `Samen.Billing.Reconciler` / `Samen.Billing.Mirror` consume.
  defp normalize_subscription(obj) do
    %{
      provider_subscription_id: obj["id"],
      provider_customer_id: ref_id(obj["customer"]),
      status: Map.get(@status_map, obj["status"], :inactive),
      current_period_start: unix(obj["current_period_start"]),
      current_period_end: unix(obj["current_period_end"]),
      trial_end: unix(obj["trial_end"]),
      cancel_at: unix(obj["cancel_at"]),
      cancelled_at: unix(obj["canceled_at"]),
      plan_ref: plan_ref(obj),
      # Proration is Stripe-computed on the invoice lines; we MIRROR the sum of the
      # proration lines, never recompute proration math (ADR-038 §3.4(4)).
      proration_amount_cents: proration_amount_cents(obj),
      currency: obj["currency"] || item_currency(obj)
    }
  end

  # Stripe invoice `status` values are ALREADY the samen-owned enum verbatim
  # (draft/open/paid/void/uncollectible) — a literal map (not `String.to_atom`)
  # so an unrecognized/future Stripe status fails honestly rather than minting a
  # new atom at runtime.
  @invoice_status_map %{
    "draft" => :draft,
    "open" => :open,
    "paid" => :paid,
    "void" => :void,
    "uncollectible" => :uncollectible
  }

  # B4+B6 (T22) — normalize a Stripe invoice object to the vendor-neutral snapshot
  # `Samen.Billing.Invoice`/`Samen.Billing.InvoiceMirror` consume. Amounts are
  # MIRRORED verbatim (`amount_due`/`amount_paid` are already minor-unit integers on
  # the Stripe object — no conversion). Tax is fail-honest (ADR-014 shape applied to
  # tax): `obj["tax"]` is `nil` when the provider computed no tax for this invoice
  # (automatic tax not enabled/applicable) — that `nil` is mirrored AS-IS, never
  # substituted with `0` (done-criterion 3). `hosted_invoice_url` is the provider's
  # hosted invoice page; the receipt link (`receipt_url/1`) comes off the expanded
  # `charge` (no PDF mirroring per ADR-038 §3.5 — `invoice_pdf` is deliberately not
  # read here).
  defp normalize_invoice(obj) do
    %{
      provider_invoice_id: obj["id"],
      provider_customer_id: ref_id(obj["customer"]),
      provider_subscription_id: ref_id(obj["subscription"]),
      status: Map.get(@invoice_status_map, obj["status"]),
      amount_due_cents: obj["amount_due"],
      amount_paid_cents: obj["amount_paid"],
      currency: obj["currency"],
      period_start: unix(obj["period_start"]),
      period_end: unix(obj["period_end"]),
      due_date: unix(obj["due_date"]),
      paid_at: unix(get_in(obj, ["status_transitions", "paid_at"])),
      line_items: invoice_line_items(obj),
      tax_amount_cents: obj["tax"],
      tax_lines: invoice_tax_lines(obj),
      hosted_invoice_url: obj["hosted_invoice_url"],
      hosted_receipt_url: receipt_url(obj),
      # B7 (T24) — the dunning retry-schedule fields, MIRRORED VERBATIM (never
      # recomputed): Stripe increments `attempt_count` on every failed charge
      # attempt against this invoice and sets `next_payment_attempt` to the
      # scheduled retry (unix seconds; `nil` once retries are exhausted or the
      # invoice is no longer being retried).
      attempt_count: obj["attempt_count"],
      next_payment_attempt: unix(obj["next_payment_attempt"])
    }
  end

  defp invoice_line_items(obj) do
    case get_in(obj, ["lines", "data"]) do
      lines when is_list(lines) ->
        Enum.map(lines, fn line ->
          %{
            "description" => line["description"],
            "amount_cents" => line["amount"],
            "quantity" => line["quantity"] || 1
          }
        end)

      _ ->
        []
    end
  end

  # `total_tax_amounts` — absent/empty when the provider computed no per-line tax
  # breakdown (fail-honest: `[]`, never an invented line).
  defp invoice_tax_lines(obj) do
    case obj["total_tax_amounts"] do
      amounts when is_list(amounts) -> Enum.map(amounts, &tax_line/1)
      _ -> []
    end
  end

  defp tax_line(%{"amount" => amount} = entry) do
    rate = entry["tax_rate"]

    %{
      "amount_cents" => amount,
      "display_name" => tax_rate_field(rate, "display_name"),
      "percentage" => tax_rate_field(rate, "percentage"),
      "jurisdiction" => tax_rate_field(rate, "jurisdiction")
    }
  end

  defp tax_line(_),
    do: %{
      "amount_cents" => nil,
      "display_name" => nil,
      "percentage" => nil,
      "jurisdiction" => nil
    }

  defp tax_rate_field(%{} = rate, key), do: Map.get(rate, key)
  defp tax_rate_field(_rate, _key), do: nil

  # The hosted RECEIPT link lives on the (expanded) charge, not the invoice itself.
  # An unexpanded `obj["charge"]` (a bare string id) is not followed — the caller's
  # `?expand[]=charge` is what makes this available in one round-trip.
  defp receipt_url(%{"charge" => %{"receipt_url" => url}}), do: url
  defp receipt_url(obj), do: obj["receipt_url"]

  defp normalize_customer(obj) do
    %{
      provider_customer_id: obj["id"],
      currency: obj["currency"],
      # Never mirror customer PII here (INV-1) — only the opaque ref + non-PII bits.
      delinquent: obj["delinquent"]
    }
  end

  # A Stripe association is either a string id or an expanded object carrying "id".
  defp ref_id(nil), do: nil
  defp ref_id(id) when is_binary(id), do: id
  defp ref_id(%{"id" => id}), do: id
  defp ref_id(_), do: nil

  defp plan_ref(obj) do
    with %{"data" => [first | _]} <- obj["items"],
         %{} = item <- first do
      ref_id(item["price"]) || ref_id(item["plan"])
    else
      _ -> nil
    end
  end

  defp item_currency(obj) do
    with %{"data" => [first | _]} <- obj["items"],
         %{"price" => %{"currency" => currency}} <- first do
      currency
    else
      _ -> nil
    end
  end

  # Sum the proration line amounts on the (expanded) latest invoice. Absent an expanded
  # invoice, proration is unknown (nil) — never fabricated as 0.
  defp proration_amount_cents(obj) do
    with %{"lines" => %{"data" => lines}} when is_list(lines) <- obj["latest_invoice"] do
      proration_lines = Enum.filter(lines, &(&1["proration"] == true))

      case proration_lines do
        [] -> nil
        some -> Enum.reduce(some, 0, fn line, acc -> acc + (line["amount"] || 0) end)
      end
    else
      _ -> nil
    end
  end

  defp unix(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  defp unix(_), do: nil

  # ---------------------------------------------------------------------------
  # Private helpers

  # Every real callback shares the same fail-honest gate: unconfigured ->
  # :not_configured; configured but not yet wired -> :not_implemented. Never a
  # fake {:ok, _}.
  defp guarded(config), do: guarded(nil, config)

  defp guarded(_attrs, config) do
    if configured?(config) do
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

  defp allowed_key?(k) when is_atom(k), do: k in @safe_keys
  defp allowed_key?(k) when is_binary(k), do: k in @safe_string_keys
  defp allowed_key?(_), do: false

  # Only plain scalars survive — an allowlisted key whose value is a map/list
  # (an expanded association, or ANY nested structure) is dropped too, never
  # assumed safe merely because its key name is on the allowlist.
  defp scalar?(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: true
  defp scalar?(_), do: false
end
