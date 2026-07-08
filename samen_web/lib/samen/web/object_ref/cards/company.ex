defmodule Samen.Web.ObjectRef.Cards.Company do
  @moduledoc """
  First-class unfurl card for `crm.company` (ADR-012 §4.4). Non-PII; title = the company name,
  plus industry/size/domain. Renders resolved values only (no company field is vaulted, so
  nothing masks here — but the card still goes through `FieldValue`, so it stays uniform).
  """

  alias Samen.Web.ObjectRef.{Card, FieldValue}

  @spec card(String.t(), module(), struct()) :: Card.t()
  def card(key, _resource, company) do
    fields =
      [
        {"Industry", FieldValue.generic(Map.get(company, :industry))},
        {"Size", FieldValue.generic(Map.get(company, :size))},
        {"Domain", FieldValue.generic(Map.get(company, :domain))}
      ]
      |> Enum.reject(fn {_l, v} -> v == nil end)

    %Card{
      key: key,
      id: company.id,
      title: FieldValue.generic(Map.get(company, :name)) || "Company",
      subtitle: "Company",
      fields: fields,
      icon: "C"
    }
  end
end
