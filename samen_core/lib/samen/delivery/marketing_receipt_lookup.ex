defmodule Samen.Delivery.MarketingReceiptLookup do
  @moduledoc """
  A REAL (not test-only) `Samen.Delivery.Deliverability` `:receipt_lookup`
  implementation for hosts using the Marketing scope (ADR-038 §4.4; C4, T30).

  `Samen.Scopes.Marketing.Send` gained a real `provider_message_id` column in
  T28 (persisted by `Samen.Delivery.Chokepoint`'s send path) — this module
  resolves a vendor `provider_message_id` back to the `%{send_id:, org_id:,
  subscriber_id:}` receipt `Samen.Delivery.Deliverability` needs to match a
  bounce/complaint/open/click event, by reading THIS mount's own `Send`
  resource through the standard Ash read path (no hardcoded table name; the
  `Samen.Scopes.Marketing.Blueprint`/`SuppressionFixture` portable-mount
  convention).

  ## Usage

      config :samen_core, Samen.Delivery.Deliverability,
        receipt_lookup: Samen.Delivery.MarketingReceiptLookup.build(Demo.MarketingScope.Send)

  `build/1` returns an arity-1 function (`provider_message_id -> {:ok, receipt} |
  :not_found | {:error, :unavailable}`) — the shape `Samen.Delivery.Deliverability` calls directly.
  """

  require Ash.Query

  @doc """
  Build a receipt-lookup function backed by `send_module` (an Ash resource
  carrying `provider_message_id`/`org_id`/`subscriber_id` attributes, the T28
  `Samen.Scopes.Marketing.Blueprint` `Send` shape).
  """
  @spec build(module()) :: (String.t() -> {:ok, map()} | :not_found | {:error, :unavailable})
  def build(send_module) when is_atom(send_module) do
    fn provider_message_id -> lookup(send_module, provider_message_id) end
  end

  defp lookup(_send_module, nil), do: :not_found

  defp lookup(send_module, provider_message_id) do
    send_module
    |> Ash.Query.filter(provider_message_id == ^provider_message_id)
    |> Ash.Query.limit(1)
    # authz-scope: webhook-ingest receipt lookup keyed on the unique provider_message_id
    # (<=1 row); org_id is read FROM the matched send row, never from the request
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} ->
        {:ok, %{send_id: row.id, org_id: row.org_id, subscriber_id: row.subscriber_id}}

      {:ok, []} ->
        :not_found

      # A read that FAILED is not "no such send": the bounce/complaint would be matched to nothing and never suppress
      # the address. It is its own, reported answer (Deliverability retries it, then the DLQ), never `:not_found`.
      {:error, reason} ->
        Samen.Observability.Failure.report(:marketing_receipt_lookup, nil, reason)
        {:error, :unavailable}
    end
  rescue
    # A host whose Send schema doesn't (yet) carry provider_message_id raises here; that is a miswired lookup, not an
    # unmatched event, so it is reported and unavailable too — never a crash of the webhook worker.
    e ->
      Samen.Observability.Failure.report(:marketing_receipt_lookup, nil, e)
      {:error, :unavailable}
  end
end
