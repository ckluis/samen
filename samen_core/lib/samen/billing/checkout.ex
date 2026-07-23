defmodule Samen.Billing.Checkout do
  @moduledoc """
  The vendor-generic B2 hosted-checkout logic (T20; ADR-038 §3.1
  `create_checkout_session`, §3.3 `:checkout_completed`/`:checkout_expired` kinds,
  §3.4 reconcile-on-event). `samen_core` owns this logic (INV-4) — the vendor adapter
  package only translates + transports; it never decides org-scoping, validation, or
  what a completed checkout activates.

  ## Session creation (`create_session/2`)

  A thin, validating wrapper around `Samen.Billing.Provider.create_checkout_session/2`:

    * required attrs present (`org_id`, `plan_id`, `price_ref`, `success_url`,
      `cancel_url`) — a missing one refuses BEFORE any provider call.
    * **tenant redirect URLs are ALWAYS org-scoped** (done-criterion 3): the caller's
      `success_url`/`cancel_url` get an `org_id` query param FORCED to the
      AUTHORITATIVE `attrs.org_id` — never trusted from the caller, never left absent.
      This is the guard against a cross-tenant redirect (a caller passing another org's
      id in the URL, or none at all) independent of whatever the UI layer (T26) sends.

  `customer_ref` is optional (a vendor's hosted checkout typically auto-creates a
  customer at checkout time when absent — no card/PII data ever transits samen either
  way, ADR-038 §3.5).

  ## Reconciliation (`reconcile/2`) — the checkout half of the dispatch seam

  `Samen.Billing.WebhookDispatch` (T21's consumer of the shared T19 dispatch seam)
  routes `:checkout_completed`/`:checkout_expired` HERE instead of to
  `Samen.Billing.Reconciler` (T21's subscription-lifecycle-sync engine) — see
  `Samen.Billing.CheckoutMirror`'s moduledoc for the full row-ownership seam between
  the two.

  ### `:checkout_completed` (the "success webhook")

  1. No `subscription_id` ref ⇒ `{:ok, :ignored}` — a non-subscription-mode checkout
     (e.g. a one-time payment) is not this task's concern (subscription checkout only).
  2. No `org_id` ref ⇒ `{:error, {:missing_ref, :org_id}}` — we cannot org-scope the write; a
     genuine defect (our own `create_session/2` always stamps `metadata.org_id`), so
     this surfaces to the worker/DLQ rather than being silently swallowed.
  3. Idempotency (done-criterion 2): `checkout_mirror.subscription_exists?/2` — a
     replayed delivery short-circuits to `{:ok, :duplicate}` BEFORE the authoritative
     re-fetch (avoids a wasted provider round-trip on a known replay; the mirror's OWN
     `activate/2` re-checks at write time as the actual race guard, see its moduledoc).
  4. Authoritative re-fetch (ADR-038 §3.4(1) — never trust the webhook payload for
     state): `provider.fetch_object(:subscription, sub_id, provider_config)`.
  5. `checkout_mirror.activate/2` creates the Subscription + Entitlement rows.

  ### `:checkout_expired` (the "cancel webhook")

  A checkout that expired/was abandoned creates NOTHING — `{:ok, :expired}`, mirror
  untouched. There is no Subscription to converge (the vendor never created one for an
  incomplete checkout), so this is a pure no-op, not a cancellation of anything.

  ### Anything else

  `{:ok, :ignored}` — defensive; `WebhookDispatch` only ever routes checkout kinds
  here, but a stray call is a safe no-op, not a crash.
  """

  alias Samen.Billing.ProviderEvent

  @required_session_attrs [:org_id, :plan_id, :price_ref, :success_url, :cancel_url]

  @type session_opts :: [provider: module(), provider_config: map()]
  @type reconcile_opts :: [
          provider: module(),
          provider_config: map(),
          checkout_mirror: module(),
          checkout_mirror_ref: term()
        ]

  @type outcome ::
          {:ok, :applied, map()}
          | {:ok, :duplicate}
          | {:ok, :expired}
          | {:ok, :ignored}
          | {:error, term()}

  @doc """
  Create a hosted checkout session for an existing Plan/Price. `attrs`:
  `%{org_id, plan_id, price_ref, success_url, cancel_url, customer_ref (optional)}`
  (ADR-038 §3.1, verbatim). `opts`: `:provider` (a `Samen.Billing.Provider` impl),
  `:provider_config`.
  """
  @spec create_session(map(), session_opts()) ::
          {:ok, %{provider_session_id: String.t(), url: String.t()}} | {:error, term()}
  def create_session(attrs, opts) when is_map(attrs) do
    provider = Keyword.fetch!(opts, :provider)
    provider_config = Keyword.get(opts, :provider_config, %{})

    case validate_session_attrs(attrs) do
      :ok -> provider.create_checkout_session(org_scope_redirects(attrs), provider_config)
      {:error, _} = err -> err
    end
  end

  @doc """
  Reconcile one normalized `Samen.Billing.ProviderEvent` of a checkout kind against the
  `Samen.Billing.CheckoutMirror`. See the moduledoc for the full per-kind contract.
  """
  @spec reconcile(ProviderEvent.t(), reconcile_opts()) :: outcome()
  def reconcile(%ProviderEvent{kind: :checkout_completed} = event, opts) do
    reconcile_checkout_completed(event, opts)
  end

  def reconcile(%ProviderEvent{kind: :checkout_expired}, _opts) do
    {:ok, :expired}
  end

  def reconcile(%ProviderEvent{}, _opts), do: {:ok, :ignored}

  # ---------------------------------------------------------------------------
  # Session creation — validation + org-scoping.

  defp validate_session_attrs(attrs) do
    missing = Enum.filter(@required_session_attrs, &blank?(Map.get(attrs, &1)))
    if missing == [], do: :ok, else: {:error, {:missing_attrs, missing}}
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # Force success_url/cancel_url to carry the AUTHORITATIVE org_id (done-criterion 3).
  # Never trusts (or merely defers to) a caller-supplied org_id already in the URL.
  defp org_scope_redirects(attrs) do
    attrs
    |> Map.put(:success_url, org_scope_url(Map.fetch!(attrs, :success_url), attrs.org_id))
    |> Map.put(:cancel_url, org_scope_url(Map.fetch!(attrs, :cancel_url), attrs.org_id))
  end

  defp org_scope_url(url, org_id) do
    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    query = Map.put(query, "org_id", to_string(org_id))
    %{uri | query: URI.encode_query(query)} |> URI.to_string()
  end

  # ---------------------------------------------------------------------------
  # Reconciliation.

  defp reconcile_checkout_completed(%ProviderEvent{provider_refs: refs} = event, opts) do
    refs = refs || %{}

    case Map.get(refs, :subscription_id) do
      nil -> {:ok, :ignored}
      sub_id -> reconcile_subscription_checkout(sub_id, refs, event, opts)
    end
  end

  defp reconcile_subscription_checkout(sub_id, refs, event, opts) do
    mirror = Keyword.fetch!(opts, :checkout_mirror)
    mirror_ref = Keyword.fetch!(opts, :checkout_mirror_ref)
    provider = Keyword.fetch!(opts, :provider)
    provider_config = Keyword.get(opts, :provider_config, %{})

    with {:ok, org_id} <- required_ref(refs, :org_id),
         {:ok, false} <- mirror.subscription_exists?(mirror_ref, sub_id),
         {:ok, snapshot} <- provider.fetch_object(:subscription, sub_id, provider_config) do
      attrs = %{
        org_id: org_id,
        plan_id: Map.get(refs, :plan_id),
        customer_ref: Map.get(refs, :customer_id),
        event_id: event.event_id,
        snapshot: Map.put(snapshot, :provider_subscription_id, sub_id)
      }

      case mirror.activate(mirror_ref, attrs) do
        {:ok, :duplicate} -> {:ok, :duplicate}
        {:ok, applied} -> {:ok, :applied, applied}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, true} -> {:ok, :duplicate}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_ref(refs, key) do
    case Map.get(refs, key) do
      nil -> {:error, {:missing_ref, key}}
      "" -> {:error, {:missing_ref, key}}
      value -> {:ok, value}
    end
  end
end
