defmodule Samen.Web.ObjectRef.Cards.Ticket do
  @moduledoc """
  First-class unfurl card for `support.ticket` (ADR-012 §4.4). Title = the ticket subject,
  plus status + priority pills and the SLA-breach flag. Non-PII (the subject is a label);
  renders resolved values only.
  """

  alias Samen.Web.ObjectRef.{Card, FieldValue}

  @spec card(String.t(), module(), struct()) :: Card.t()
  def card(key, _resource, ticket) do
    badges =
      [
        {status_variant(Map.get(ticket, :status)), FieldValue.generic(Map.get(ticket, :status))},
        {priority_variant(Map.get(ticket, :priority)), FieldValue.generic(Map.get(ticket, :priority))}
      ]
      |> Enum.reject(fn {_v, l} -> l == nil end)

    fields =
      [
        {"Breached", breached_label(Map.get(ticket, :breached))},
        {"Tags", tags_label(Map.get(ticket, :tags))}
      ]
      |> Enum.reject(fn {_l, v} -> v == nil end)

    %Card{
      key: key,
      id: ticket.id,
      title: FieldValue.generic(Map.get(ticket, :subject)) || "Ticket",
      subtitle: "Support ticket",
      fields: fields,
      badges: badges,
      icon: "T"
    }
  end

  defp status_variant(:open), do: "ok"
  defp status_variant(:pending), do: "warn"
  defp status_variant(status) when status in [:closed, :resolved], do: "mut"
  defp status_variant(_), do: "info"

  defp priority_variant(p) when p in [:high, :urgent], do: "bad"
  defp priority_variant(:normal), do: "info"
  defp priority_variant(_), do: "mut"

  defp breached_label(true), do: "SLA breached"
  defp breached_label(_), do: nil

  defp tags_label([_ | _] = tags), do: Enum.join(tags, ", ")
  defp tags_label(_), do: nil
end
