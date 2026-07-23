defmodule SamenStripe.Transport do
  @moduledoc """
  Default (real) HTTP transport for the samen-initiated `SamenStripe.Provider` calls
  (`fetch_object/3`, `cancel_subscription/3`, `change_subscription/3` — B3/T21) — a
  plain `Req` request to Stripe's REST API with `Bearer` auth.

  Every one of those callbacks accepts an injectable `config[:transport]` (an arity-1
  function `request_map -> {:ok, %{status:, body:}} | {:error, term()}`) that, when
  present, REPLACES this module. The lifecycle-sync fixture harness (and any other
  hermetic lane-0 test, ADR-038 §7.1/§7.2) supplies a cassette-serving transport there,
  so `mix test` NEVER touches the network and needs no Stripe credential. This module
  runs for real only in the operator-gated live smoke lane (`STRIPE_TEST_KEY`, §7.1
  lane 1). This mirrors the `SamenPostmark.Transport` injectable-transport precedent.

  ## Request shape

      %{method: :get | :post | :delete,
        url: "https://api.stripe.com/v1/subscriptions/sub_123",
        secret_key: "sk_test_...",
        form: %{"cancel_at_period_end" => true},   # POST only; form-encoded per Stripe
        idempotency_key: "usage:ur_123"}           # optional (T25/B8) — sent as
                                                    # Stripe's `Idempotency-Key` header

  Returns `{:ok, %{status: integer(), body: map() | binary()}}` (Req auto-decodes JSON
  to a map) or `{:error, reason}` on a transport-level failure (DNS/connect/timeout).
  """

  @doc "Perform a real Stripe API request. See the moduledoc for the request shape."
  @spec live(map()) :: {:ok, map()} | {:error, term()}
  def live(%{method: method, url: url, secret_key: secret_key} = request) do
    headers = [{"accept", "application/json"}] ++ idempotency_header(request)
    base = [auth: {:bearer, secret_key}, headers: headers]

    result =
      case method do
        :get -> Req.get(url, base)
        :delete -> Req.delete(url, base)
        :post -> Req.post(url, Keyword.put(base, :form, Map.get(request, :form, %{})))
      end

    case result do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # T25/B8 — Stripe dedups a repeated `report_usage/2` call on this header, so a
  # retry of a still-pending batch (Samen.Billing.UsageReporter never marks
  # anything on error) never double-bills. Absent/blank ⇒ no header, unchanged
  # behavior for every OTHER (non-usage) call this transport serves.
  defp idempotency_header(%{idempotency_key: key}) when is_binary(key) and key != "" do
    [{"idempotency-key", key}]
  end

  defp idempotency_header(_request), do: []
end
