defmodule Samen.Web.ObjectRef.Cards.Person do
  @moduledoc """
  First-class unfurl card for `crm.person` (ADR-012 §4.4). Title = the person's name
  (`%Masked{}` → `••••` on the operator plane), plus company/job/email/phone and a
  lifecycle-stage badge.

  MASKING: the record was ALREADY resolved for the viewer's plane by
  `Samen.Web.ObjectRef.resolve/3`. This card only LAYS OUT resolved values through
  `Samen.Web.ObjectRef.FieldValue` (which passes a `%Masked{}` through untouched). It never
  reads a column directly nor unwraps a mask.
  """

  alias Samen.Web.ObjectRef.{Card, FieldValue}

  @spec card(String.t(), module(), struct()) :: Card.t()
  def card(key, _resource, person) do
    title = FieldValue.full_name(Map.get(person, :full_name), Map.get(person, :display_name))

    fields =
      [
        {"Title", FieldValue.generic(Map.get(person, :job_title))},
        {"Email", FieldValue.email(Map.get(person, :emails))},
        {"Phone", FieldValue.phone(Map.get(person, :phones))}
      ]
      |> Enum.reject(fn {_l, v} -> v in [nil, "—"] end)

    %Card{
      key: key,
      id: person.id,
      title: title,
      subtitle: "Contact",
      fields: fields,
      badges: lifecycle_badge(person),
      icon: "P"
    }
  end

  defp lifecycle_badge(%{custom: %{"lifecycle_stage" => stage}}) when is_binary(stage) do
    [{lifecycle_variant(stage), stage}]
  end

  defp lifecycle_badge(_), do: []

  defp lifecycle_variant(stage) when stage in ["lead", "mql"], do: "info"
  defp lifecycle_variant(stage) when stage in ["sql", "opportunity"], do: "warn"
  defp lifecycle_variant("customer"), do: "ok"
  defp lifecycle_variant(_), do: "mut"
end
