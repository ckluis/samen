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
  :not_found`) — the shape `Samen.Delivery.Deliverability` calls directly.
  """

  require Ash.Query

  @doc """
  Build a receipt-lookup function backed by `send_module` (an Ash resource
  carrying `provider_message_id`/`org_id`/`subscriber_id` attributes, the T28
  `Samen.Scopes.Marketing.Blueprint` `Send` shape).
  """
  @spec build(module()) :: (String.t() -> {:ok, map()} | :not_found)
  def build(send_module) when is_atom(send_module) do
    fn provider_message_id -> lookup(send_module, provider_message_id) end
  end

  defp lookup(_send_module, nil), do: :not_found

  defp lookup(send_module, provider_message_id) do
    send_module
    |> Ash.Query.filter(provider_message_id == ^provider_message_id)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [row]} -> {:ok, %{send_id: row.id, org_id: row.org_id, subscriber_id: row.subscriber_id}}
      _ -> :not_found
    end
  rescue
    # A host whose Send schema doesn't (yet) carry provider_message_id, or any
    # other read hiccup, degrades to "couldn't match" — never a crash of the
    # webhook worker (the ADR-038 fail-honest posture: an unmatched event goes
    # to the DLQ, it never takes the pipeline down).
    _ -> :not_found
  end
end
