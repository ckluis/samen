defmodule Samen.Web.ObjectRef.Cards.Invoice do
  @moduledoc """
  First-class unfurl card for `billing.invoice` (ADR-012 §4.4). Title = a formatted amount
  (`$299.00`), plus a status pill and the due date. Non-PII on the invoice row itself (the
  customer's billing_name/email are vaulted on the CUSTOMER, not here); renders resolved
  values only.
  """

  alias Samen.Web.ObjectRef.{Card, FieldValue}

  @spec card(String.t(), module(), struct()) :: Card.t()
  def card(key, _resource, invoice) do
    amount = money(Map.get(invoice, :amount_due_cents), Map.get(invoice, :currency))

    fields =
      [
        {"Paid", money(Map.get(invoice, :amount_paid_cents), Map.get(invoice, :currency))},
        {"Due", FieldValue.generic(Map.get(invoice, :due_date))}
      ]
      |> Enum.reject(fn {_l, v} -> v in [nil, "—"] end)

    %Card{
      key: key,
      id: invoice.id,
      title: amount,
      subtitle: "Invoice",
      fields: fields,
      badges: [{status_variant(Map.get(invoice, :status)), FieldValue.generic(Map.get(invoice, :status))}],
      icon: "$"
    }
  end

  defp status_variant(:paid), do: "ok"
  defp status_variant(:open), do: "warn"
  defp status_variant(s) when s in [:void, :uncollectible, :past_due], do: "bad"
  defp status_variant(_), do: "info"

  defp money(cents, currency) when is_integer(cents) do
    symbol = currency_symbol(currency)
    "#{symbol}#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
  end

  defp money(_, _), do: nil

  defp currency_symbol("USD"), do: "$"
  defp currency_symbol("EUR"), do: "€"
  defp currency_symbol("GBP"), do: "£"
  defp currency_symbol(_), do: "$"
end
