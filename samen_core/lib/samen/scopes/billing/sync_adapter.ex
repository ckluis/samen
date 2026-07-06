defmodule Samen.Scopes.Billing.SyncAdapter do
  @moduledoc """
  The **Stripe-sync adapter behaviour** for the Billing scope (T3.3).

  The Billing scope is a **Stripe-mirror shape** — an internal, governed representation
  of billing objects. No live Stripe API calls are made inside the scope resources
  themselves. Instead, host applications that wish to synchronize with Stripe implement
  this behaviour and wire it into their pipeline (e.g. via a webhook handler or an
  Oban job).

  ## Why a behaviour, not a direct integration

  Direct Stripe API calls from inside Ash resource actions would:
    1. Break the "one Postgres per product" governance model (side-effect coupling).
    2. Make the resources untestable without live API credentials.
    3. Couple the scope's schema to Stripe's API version.

  The seam here is: **resources own the governed mirror**; **the adapter owns the sync**.
  The mirror is always authoritative for policy, vault, catalog, and the operator plane.
  The adapter is always opt-in, host-owned.

  ## Implementing the behaviour

  Implement this behaviour in your host application and configure it:

      # config/config.exs
      config :my_app, :billing_sync_adapter, MyApp.Billing.StripeAdapter

  Then implement each callback (use the Stub as a reference):

      defmodule MyApp.Billing.StripeAdapter do
        @behaviour Samen.Scopes.Billing.SyncAdapter

        @impl true
        def sync_customer(billing_customer, _opts) do
          # Call Stripe, return {:ok, %{stripe_customer_id: "cus_..."}} or {:error, reason}
        end

        # ... other callbacks
      end

  ## No live Stripe calls — the Stub

  `Samen.Scopes.Billing.SyncAdapter.Stub` is the default adapter. It records sync
  calls in process state (suitable for tests and environments without Stripe credentials)
  and returns successful no-op results. CI always runs against the Stub.
  """

  @type customer_attrs :: %{
          id: binary(),
          org_id: binary(),
          status: atom(),
          stripe_customer_id: binary() | nil
        }

  @type subscription_attrs :: %{
          id: binary(),
          org_id: binary(),
          customer_id: binary(),
          plan_id: binary() | nil,
          status: atom(),
          stripe_subscription_id: binary() | nil
        }

  @type invoice_attrs :: %{
          id: binary(),
          org_id: binary(),
          customer_id: binary(),
          stripe_invoice_id: binary() | nil,
          amount_due_cents: integer()
        }

  @type sync_result :: {:ok, map()} | {:error, term()}

  @doc """
  Sync a billing customer to the external billing provider.
  Returns `{:ok, %{stripe_customer_id: id}}` on success, `{:error, reason}` on failure.
  On a no-live-integration stub, returns `{:ok, %{}}`.
  """
  @callback sync_customer(customer_attrs :: customer_attrs(), opts :: keyword()) :: sync_result()

  @doc """
  Sync a subscription to the external billing provider.
  Returns `{:ok, %{stripe_subscription_id: id}}` on success.
  """
  @callback sync_subscription(
              subscription_attrs :: subscription_attrs(),
              opts :: keyword()
            ) :: sync_result()

  @doc """
  Sync an invoice to the external billing provider.
  Returns `{:ok, %{stripe_invoice_id: id}}` on success.
  """
  @callback sync_invoice(invoice_attrs :: invoice_attrs(), opts :: keyword()) :: sync_result()

  @doc """
  Cancel a subscription at the external billing provider.
  Returns `{:ok, %{}}` on success.
  """
  @callback cancel_subscription(subscription_id :: binary(), opts :: keyword()) :: sync_result()

  # ---------------------------------------------------------------------------
  # Stub implementation — no live Stripe calls, records invocations for tests.
  # ---------------------------------------------------------------------------

  defmodule Stub do
    @moduledoc """
    The default no-op sync adapter (T3.3 spec: "a sync-adapter behaviour stub").

    Records sync calls in a process-local accumulator (via the process dictionary)
    so tests can assert the adapter was called without live Stripe credentials.
    Returns successful no-op results for all callbacks.

    Used in test and dev environments. Production apps should implement the full
    `Samen.Scopes.Billing.SyncAdapter` behaviour with real Stripe API calls.
    """

    @behaviour Samen.Scopes.Billing.SyncAdapter

    @impl true
    def sync_customer(customer_attrs, _opts) do
      record_call(:sync_customer, customer_attrs)
      {:ok, %{stub: true, synced_at: DateTime.utc_now()}}
    end

    @impl true
    def sync_subscription(subscription_attrs, _opts) do
      record_call(:sync_subscription, subscription_attrs)
      {:ok, %{stub: true, synced_at: DateTime.utc_now()}}
    end

    @impl true
    def sync_invoice(invoice_attrs, _opts) do
      record_call(:sync_invoice, invoice_attrs)
      {:ok, %{stub: true, synced_at: DateTime.utc_now()}}
    end

    @impl true
    def cancel_subscription(subscription_id, _opts) do
      record_call(:cancel_subscription, %{subscription_id: subscription_id})
      {:ok, %{stub: true, cancelled_at: DateTime.utc_now()}}
    end

    @doc """
    Returns all recorded sync calls for the current process. Useful in tests:

        alias Samen.Scopes.Billing.SyncAdapter.Stub
        Stub.sync_customer(%{id: "...", org_id: "..."}, [])
        assert {:sync_customer, _} = hd(Stub.calls())
    """
    def calls do
      Process.get(:billing_sync_stub_calls, [])
    end

    @doc "Clear the recorded calls for the current process."
    def reset, do: Process.put(:billing_sync_stub_calls, [])

    defp record_call(callback, attrs) do
      current = Process.get(:billing_sync_stub_calls, [])
      Process.put(:billing_sync_stub_calls, [{callback, attrs} | current])
    end
  end
end
