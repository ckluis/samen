defmodule Samen.Web.ObjectRef.DefaultCard do
  @moduledoc """
  The CATALOG-DRIVEN default card (ADR-012 §4.4) — renders ANY catalogued resource,
  masking-aware per viewer, with ZERO cards written. The framework promise: a resource nobody
  has ever seen unfurls the day it is catalogued, and a vaulted field on it masks correctly on
  the operator plane via the SAME resolver, because the record was ALREADY resolved before this
  module sees it.

  ## How it is correct for a never-before-seen resource

    * **title** — the first present display attribute by convention (`:name`, `:display_name`,
      `:subject`, `:handle`, `:full_name`, `:billing_name`, `:number`, `:title`). Because a
      vaulted title (e.g. `:full_name`) arrives as a `%Masked{}` on the operator plane, the
      title itself masks to `••••` correctly — no special case.
    * **fields** — the resource's PUBLIC attributes (skipping ids/timestamps/org/the title
      attr/the custom bag), each formatted through `Samen.Web.ObjectRef.FieldValue` which
      passes a `%Masked{}` through untouched. The `pii do` declaration is honored TRANSITIVELY:
      the vaulted field was already resolved to `%Masked{}` (operator) / plaintext (tenant) in
      `Samen.Web.ObjectRef.resolve/3` step 3 before this module ran.
    * **badges** — bounded-enum attributes (`:status`, `:priority`, `:stage`, `:stage_type`,
      `:lifecycle_stage`) become pills.
    * **subtitle** — the catalog resource key (a masking-neutral kicker).

  This module NEVER reads a column directly, NEVER unwraps a `%Masked{}`, and NEVER produces
  plaintext — it only LAYS OUT already-resolved values.
  """

  alias Samen.Web.ObjectRef.{Card, FieldValue}

  # Attribute names, in priority order, that make a good card title. `full_name` (the vaulted
  # identity) ranks ABOVE `display_name` so a person card's TITLE masks to `••••` on the
  # operator plane by construction — the framework-promise property (a vaulted field is the
  # face of the card, and it masks). A non-PII resource falls through to `name`/`subject`/etc.
  @title_attrs [:name, :subject, :full_name, :billing_name, :number, :title, :handle, :display_name, :label]

  # Attribute names that carry a bounded enum worth a pill.
  @badge_attrs [:status, :priority, :stage, :stage_type, :lifecycle_stage, :state, :kind]

  # Attribute names never shown as a body field (structural / noisy).
  @skip_attrs [:id, :org_id, :inserted_at, :updated_at, :custom, :__meta__, :__struct__]

  @doc "Build a `%Card{}` from a RESOLVED record + its resource + the catalog key."
  @spec card(String.t(), module(), struct()) :: Card.t()
  def card(key, resource, record) do
    title_attr = pick_title_attr(resource)
    title = title_value(record, title_attr)

    %Card{
      key: key,
      id: to_id(record),
      title: title,
      subtitle: key,
      fields: body_fields(resource, record, title_attr),
      badges: badges(resource, record),
      icon: icon_for(key)
    }
  end

  # -- title -------------------------------------------------------------------

  defp pick_title_attr(resource) do
    names = public_attr_names(resource)
    Enum.find(@title_attrs, :display_name, fn a -> a in names end)
  end

  defp title_value(record, :full_name) do
    FieldValue.full_name(Map.get(record, :full_name), Map.get(record, :display_name))
  end

  defp title_value(record, attr) do
    case Map.get(record, attr) do
      nil -> fallback_title(record)
      value -> FieldValue.generic(value) || fallback_title(record)
    end
  end

  defp fallback_title(record) do
    FieldValue.generic(Map.get(record, :display_name)) || "Object"
  end

  # -- body fields -------------------------------------------------------------

  defp body_fields(resource, record, title_attr) do
    resource
    |> public_attributes()
    |> Enum.reject(fn attr -> attr.name in @skip_attrs or attr.name == title_attr end)
    |> Enum.reject(fn attr -> attr.name in @badge_attrs end)
    |> Enum.map(fn attr -> {FieldValue.humanize(attr.name), field_value(record, attr)} end)
    |> Enum.reject(fn {_label, value} -> value == nil end)
    # Keep the card compact — the default card is a preview, not a detail page.
    |> Enum.take(6)
  end

  defp field_value(record, %{name: :full_name}) do
    FieldValue.full_name(Map.get(record, :full_name), Map.get(record, :display_name))
  end

  defp field_value(record, %{name: name}) when name in [:emails, :email] do
    FieldValue.email(Map.get(record, name))
  end

  defp field_value(record, %{name: name}) when name in [:phones, :phone] do
    FieldValue.phone(Map.get(record, name))
  end

  defp field_value(record, %{name: name}) do
    FieldValue.generic(Map.get(record, name))
  end

  # -- badges ------------------------------------------------------------------

  defp badges(resource, record) do
    names = public_attr_names(resource)

    @badge_attrs
    |> Enum.filter(fn a -> a in names end)
    |> Enum.map(fn a -> {a, Map.get(record, a)} end)
    |> Enum.reject(fn {_a, v} -> v == nil end)
    |> Enum.map(fn {a, v} -> {badge_variant(a, v), badge_label(v)} end)
  end

  # A masked badge value should never happen (bounded enums aren't PII) but stay safe.
  defp badge_label(%Samen.Masked{} = m), do: m
  defp badge_label(v) when is_atom(v), do: v |> Atom.to_string() |> String.replace("_", " ")
  defp badge_label(v) when is_binary(v), do: String.replace(v, "_", " ")
  defp badge_label(v), do: to_string(v)

  # Map a status/priority atom to a pill variant. Bounded, presentational.
  defp badge_variant(_attr, v) when v in [:open, :active, :won, :completed, :paid], do: "ok"
  defp badge_variant(_attr, v) when v in [:high, :urgent, :pending, :on_hold], do: "warn"
  defp badge_variant(_attr, v) when v in [:lost, :closed, :cancelled, :failed, :past_due], do: "bad"
  defp badge_variant(_attr, "high"), do: "warn"
  defp badge_variant(_attr, "urgent"), do: "warn"
  defp badge_variant(_attr, _v), do: "info"

  # -- introspection helpers ---------------------------------------------------

  defp public_attributes(resource) do
    Ash.Resource.Info.public_attributes(resource)
  rescue
    _ -> []
  end

  defp public_attr_names(resource) do
    resource |> public_attributes() |> Enum.map(& &1.name)
  end

  defp to_id(record) do
    case Map.get(record, :id) do
      id when is_binary(id) -> id
      id -> to_string(id)
    end
  end

  defp icon_for(key) do
    key |> String.split(".") |> List.last() |> String.slice(0, 1) |> String.upcase()
  end
end
