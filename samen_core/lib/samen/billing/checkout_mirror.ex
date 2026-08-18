defmodule Samen.Billing.CheckoutMirror do
  @moduledoc """
  The **checkout-activation mirror port** the `Samen.Billing.Checkout` reconciler (B2;
  T20) writes through (ADR-038 §3.1 `create_checkout_session` + §3.4 convergence model,
  the `:checkout_completed`/`:checkout_expired` branch T21's `Samen.Billing.Mirror`
  moduledoc named as "owners consume the same dispatch seam").

  ## Why a SEPARATE port from `Samen.Billing.Mirror` (the seam vs T21, spelled out)

  T21's `Samen.Billing.Mirror` converges an EXISTING subscription (lifecycle sync:
  update/upgrade/cancel via re-fetch) and ships only the in-memory `FakeMirror` — the
  production Ash-backed impl is deferred to T106 because the watermark/last-event-id
  bookkeeping it needs has no storage yet.

  T20 (checkout) has a DIFFERENT job: activate a BRAND NEW Subscription + its
  Entitlement rows from a completed checkout, writing onto the EXISTING billing
  Plan/Price/Subscription/Entitlement Ash resources — fields that already exist on the
  blueprint (the provider-ref attribute, `status`, `current_period_*`, `Entitlement`).
  No new columns are needed, so unlike T21's mirror, T20 ships the REAL Ash-backed
  impl (`Samen.Billing.AshCheckoutMirror`) now, not deferred.

  **The row-ownership seam (read this before touching either mirror):** a
  `:checkout_completed` event is the ONLY thing that ever CREATES a Subscription row
  (via this port). Every subsequent subscription webhook (`:subscription_updated`,
  `:subscription_deleted`, …) converges that SAME row through T21's `Mirror` port. The
  two ports never race for the same write: `CheckoutMirror.activate/2` is idempotent by
  `provider_subscription_id` (a duplicate `:checkout_completed` delivery, or an
  after-the-fact `:subscription_updated` for a subscription this port already created,
  both see "already exists" from their own port's perspective) — `T106` unifies the two
  ports' storage (e.g. one shared watermark) once the production `Mirror` lands, but
  today they are two independent read/write surfaces over the same `bsb_subscription`
  table, and that is safe ONLY because `CheckoutMirror` only ever INSERTs (never
  updates an existing row) and `Mirror`'s production impl (T106, not yet shipped) would
  only ever UPDATE.

  ## The contract

    * `subscription_exists?/2` — idempotency read: has THIS provider subscription id
      already been activated? (Done-criterion 2: "success delivered twice ⇒ ONE
      subscription".)
    * `activate/2` — create the Subscription + one Entitlement row per plan feature.
      MUST be idempotent by `provider_subscription_id` (a second call after an
      existing activation is a safe no-op — `{:ok, :duplicate}` — never a second row).

  ## Implementations

    * `Samen.Billing.FakeCheckoutMirror` — in-memory, ships in lib (test infra
      precedent). Proves `Samen.Billing.Checkout`'s routing/idempotency hermetically
      (no DB, no Ash resources) — mirrors the `Samen.Billing.FakeMirror` shape.
    * `Samen.Billing.AshCheckoutMirror` — the REAL, resource-module-agnostic impl.
      References ONLY Ash (already a `samen_core` dependency, not a vendor — INV-4
      concerns the billing vendor/HTTP deps, not the Ash framework itself) — never a vendor
      module. The host's concrete resource modules are resolved via the `ref` map
      (mirrors how `Samen.Billing.WebhookDispatch` resolves `:billing_provider` /
      `:billing_mirror` from host config).
  """

  @type ref :: term()

  @type activation_attrs :: %{
          required(:org_id) => String.t(),
          required(:snapshot) => map(),
          optional(:plan_id) => String.t() | nil,
          optional(:customer_ref) => String.t() | nil,
          optional(:event_id) => String.t()
        }

  @doc """
  Has a Subscription already been activated for this `provider_subscription_id`? The
  idempotency read (done-criterion 2) — checked BEFORE any authoritative re-fetch, so a
  replayed `:checkout_completed` short-circuits without a wasted provider round-trip.
  """
  @callback subscription_exists?(ref(), provider_subscription_id :: String.t()) ::
              {:ok, boolean()} | {:error, term()}

  @doc """
  Activate (create) a Subscription + its Entitlement rows from a completed checkout.
  `attrs.snapshot` is the AUTHORITATIVE subscription snapshot (the same shape
  `Samen.Billing.Provider.fetch_object/3` returns — never trust the raw webhook
  payload for state, ADR-038 §3.4(1)).

  MUST be idempotent by `snapshot.provider_subscription_id`: a second `activate/2` call
  for an already-activated subscription returns `{:ok, :duplicate}`, never a second row.
  """
  @callback activate(ref(), activation_attrs()) ::
              {:ok, map()} | {:ok, :duplicate} | {:error, term()}
end
